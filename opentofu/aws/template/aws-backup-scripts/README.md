# AWS Backup for EKS — operator's guide

Scripts for manually triggering, listing, restoring, and verifying AWS Backup
recovery points for this environment's EKS cluster.

This is a companion to the `backup` Terraform module
(`opentofu/aws/modules/backup/`), which creates the vault/plan/IAM roles and
runs the *scheduled* backup automatically (daily or weekly, per
`backup_schedule`). The scripts here cover everything else: an on-demand
backup, finding a recovery point, restoring it, and checking it actually
worked.

---

## Prerequisites

- `aws` CLI configured with a profile that has AWS Backup / EC2 / IAM access
  in this environment's account — `export AWS_PROFILE=...` first.
- `jq` and `kubectl` installed.
- Run these from `<env>/aws-backup-scripts/`. They read `<env>/global-values.yaml`
  one directory up to resolve the vault name, IAM role ARNs and cluster name
  automatically — nothing is hardcoded, so copying the whole `<env>/`
  directory brings these scripts with it, working unchanged.

---

## The scripts

| Script | What it does |
|---|---|
| `trigger-backup.sh` | Starts an on-demand backup of this environment's cluster. |
| `backup-status.sh <job-id> [--watch]` | Checks a backup job's status. |
| `list-recovery-points.sh [--latest]` | Lists this environment's composite recovery points, newest first. |
| `trigger-restore.sh` | Starts a restore — full cluster or specific namespaces — from a recovery point into a target cluster. |
| `restore-status.sh <job-id> [--watch]` | Checks a restore job's status, including every nested per-volume child job. |
| `verify-restore.sh [namespace ...]` | Checks pod/PVC health on whatever cluster `KUBECONFIG` points at. No arguments = every namespace. |

Every script has `-h`/`--help`. Every write-type command prints the exact
`aws backup ...` call it's about to run before running it — add `--dry-run`
to see it without executing.

---

## 1. Trigger a backup

```bash
cd <env>/aws-backup-scripts
export AWS_PROFILE=<your-profile>

./trigger-backup.sh
# -> { "BackupJobId": "..." }
./backup-status.sh <BackupJobId> --watch
```

---

## 2. Find the recovery point

```bash
./list-recovery-points.sh            # see all of them
./list-recovery-points.sh --latest   # just the newest ARN
```

`trigger-restore.sh` uses the latest one automatically unless you pass
`--recovery-point-arn` — only needed if you want a specific day's backup.

> **A recovery point is a composite, not a single thing.** One backup run
> produces one child recovery point for the Kubernetes cluster state, plus
> one per backed-up PersistentVolume — a healthy composite has
> `1 + (number of PVs)` children. Only a cluster-state child with no PV
> children means the backup captured the cluster's shape but not its data —
> check the source cluster's default StorageClass is CSI-backed
> (`ebs.csi.aws.com`), not the legacy `kubernetes.io/aws-ebs` plugin.

---

## 3. Restore it

Get the target cluster's AZ first — EBS volumes are AZ-locked, so the wrong
one leaves the pod stuck `Pending`/`FailedScheduling`:

```bash
kubectl get nodes -o jsonpath='{.items[0].metadata.labels.topology\.kubernetes\.io/zone}'
```

```bash
# full cluster
./trigger-restore.sh --target-cluster <name> --az <az>

# just specific namespaces (up to 5) -- needs the SOURCE cluster's kubeconfig,
# since AWS Backup's recovery-point metadata only exposes PV names, never
# which namespace they belonged to
export KUBECONFIG=/path/to/source-cluster-kubeconfig.yaml
./trigger-restore.sh --target-cluster <name> --az <az> --namespaces common-services,monitoring
```

> `--target-cluster` and `--az` are always required and never defaulted —
> restoring into the wrong cluster, or the wrong AZ, is the failure mode this
> is guarding against. For a real disaster-recovery restore, the target is
> usually the **same** cluster that's still running (just missing the
> deleted workload); for testing the backup itself, point it at a separate
> throwaway cluster instead.

---

## 4. Track it

```bash
./restore-status.sh <RestoreJobId> --watch
```

> **"Some Kubernetes Objects failed to be restored" on the EKS child job is
> common and often meaningless.** It shows up on nearly every restore,
> including ones where everything came back perfectly — AWS silently skips
> auto-regenerated objects (`Endpoints`, `EndpointSlices`, `CSINodes`,
> `VolumeAttachments`) that Kubernetes recreates on its own. Never trust this
> message alone in either direction — confirm with `verify-restore.sh` below.

---

## 5. Verify it

```bash
export KUBECONFIG=/path/to/target-cluster-kubeconfig.yaml
./verify-restore.sh                              # every namespace
./verify-restore.sh common-services monitoring   # just the ones you restored
```

Flags anything not `Running`/ready, any PVC not `Bound`, and the last 10
Warning events for namespaces with an actual problem.

---

## 6. Verify data, not just pods

`verify-restore.sh` proves pods are healthy and PVCs are bound — it does
**not** prove the data inside a database is real and complete. Compare row
counts instead:

```bash
kubectl exec -n <ns> <postgres-pod> -- bash -c \
  'PGPASSWORD=$(cat /opt/bitnami/postgresql/secrets/postgres-password) \
   psql -U postgres -d <db> -c "SELECT count(*) FROM <table>;"'
```

(Adjust the secrets path if the Postgres image/chart differs — this is the
Bitnami layout used by `common-services`.)

> Don't use `pg_stat_user_tables.n_live_tup` for this — it's a stale
> statistics-collector estimate, and reads `0` or stale right after a cold
> start from a restored volume even when the real data is there. Run an
> actual `SELECT count(*)`.

> **A lower count on the target than the source is expected, not data
> loss**, if the source kept running after the backup was taken. Confirm by
> filtering a timestamp column against the recovery point's creation time:
> rows from before the backup should match almost exactly; the "missing"
> ones should all have been created after.

---

## Cleaning up after a restore test

Restored PVs are backed by **untagged** EBS volumes. The EBS CSI driver's IAM
policy only grants `DeleteVolume` on volumes carrying tags it stamps on
volumes it provisions itself, so a restored volume can never be cleanly
deleted by the CSI driver once its PVC is gone — it sits `Released` forever
and keeps costing money until removed manually:

```bash
# 1. if the namespace hangs in Terminating, check for a dangling APIService
#    (metrics-server living in the deleted namespace is the usual cause)
kubectl get apiservices | grep -v True
kubectl delete apiservice <the broken one>   # safe -- it's just a stale pointer

# 2. find PVs stuck in Released phase
kubectl get pv

# 3. confirm the volume is genuinely orphaned, then delete it for real --
#    the CSI driver can't do this step itself
aws ec2 describe-volumes --volume-ids <id> --query 'Volumes[0].{State:State,Attachments:Attachments[0].State}'
aws ec2 delete-volume --volume-id <id>

# 4. only after the real volume is confirmed gone, remove the PV's finalizers
kubectl patch pv <name> -p '{"metadata":{"finalizers":null}}' --type=merge
```

> Don't skip to step 4 without 2–3 first — removing a PV's finalizer before
> the real volume is deleted orphans it with nothing left to track it.

If the target cluster has the full app stack deployed, `<env>/install.sh
cleanup_all_services` is the repo's own proper teardown (Helm releases +
cert-manager's cluster-scoped CRDs/webhooks) — it still won't resolve the
stuck-PV issue above; you'll need the manual volume cleanup afterward either
way.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Composite recovery point has only the cluster-state child, no PV children | Backup didn't capture volume data — check the source cluster's StorageClass is CSI-backed. |
| `AccessDenied: iam:PassRole` when triggering a restore | Account IAM policy doesn't allow passing the restore role to `backup.amazonaws.com` — account-admin fix, not in this repo. |
| `FailedScheduling: ... bound to non-existent persistentvolume ... not found` | PVC restored but its PV didn't, or a stale PV from an earlier test is blocking it — see "Cleaning up" above. |
| Restored pods crash-looping across several namespaces | Usually a cascade from one real problem (commonly Postgres/Redis not binding) — fix the root PV/PVC issue first and recheck. |
| Namespace stuck in `Terminating` | `kubectl get namespace <ns> -o jsonpath='{.status.conditions}'` names the exact blocker — a dangling `metrics.k8s.io` APIService is the most common and is safe to delete directly. |

---

## Reference

- **Two IAM roles, on purpose.** `<env>-eks-backup-role` runs the scheduled
  backup and only has backup permissions. `<env>-eks-backup-restore-role` is
  what these scripts use for restores — a separate, more powerful policy,
  never attached to anything that runs unattended.

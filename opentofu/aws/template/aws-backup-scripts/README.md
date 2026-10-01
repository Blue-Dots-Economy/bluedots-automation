# AWS Backup for EKS — operator's guide

Scripts for manually triggering, listing, restoring, and verifying AWS Backup
recovery points for this environment's EKS cluster. If you've never touched
this feature before, read this whole document before running anything — the
"Concepts" section below explains a few things that aren't obvious and will
save you from a confusing failure later.

This is a companion to the `backup` Terraform module (`opentofu/aws/modules/backup/`)
and its wiring (`opentofu/aws/_common/backup.hcl`, `backup_*` keys in
`global-values.yaml`). That module creates the vault/plan/IAM roles and runs the
*scheduled* backup automatically (daily or weekly, per `backup_schedule`). The
scripts here are for everything you'd otherwise have to click through the AWS
Backup console for: triggering an on-demand backup, finding a recovery point,
restoring it, and checking whether the restore actually worked.

## Prerequisites

- `aws` CLI configured with a profile that has AWS Backup / EC2 / IAM read
  access in this environment's account.
- `jq` and `kubectl` installed.
- You're running these scripts from inside `<env>/aws-backup-scripts/` — they
  read `<env>/global-values.yaml` (one directory up) to figure out the vault
  name, IAM role ARNs, and cluster name automatically. **Nothing here is
  hardcoded to a specific environment** — copy the whole `<env>/` directory
  (which includes this folder, since it comes from `opentofu/aws/template/`)
  and these scripts work unchanged for that environment.
- `export AWS_PROFILE=...` (and `KUBECONFIG=...` for anything that touches a
  cluster directly) before running anything, same as every other command in
  this repo.

## Concepts — read this before your first restore

**A "recovery point" is a composite, not a single thing.** Every backup run
produces one *composite* recovery point — think of it as a folder — containing
one *child* recovery point for the Kubernetes cluster state (manifests,
secrets, configmaps) and one child per PersistentVolume that was backed up. A
healthy backup composite therefore has `1 + (number of PVs)` children. If you
ever see only the cluster-state child and no PV children, the backup
captured the shape of the cluster but not the actual data — see
"Troubleshooting" below.

**Two IAM roles, on purpose, not a config oversight.** `<env>-eks-backup-role`
runs the nightly/weekly scheduled backup and only has backup permissions.
`<env>-eks-backup-restore-role` is the one these scripts use for restores — it
carries the separate, more powerful restore policy and is never attached to
anything that runs unattended. Don't be surprised these are different ARNs.

**Restoring into the same cluster vs. a different one.** `--target-cluster`
is always required and never defaulted, on purpose:
- **Real disaster recovery** (someone deleted a namespace/PVCs in a live
  cluster): target is the **same** cluster that's still running, just missing
  the workloads. The old PV/volume for whatever was deleted is almost
  certainly **already gone** by the time you decide to restore — that's the
  whole point of having a backup. The restore creates a **brand-new EBS
  volume** from the snapshot; you never reuse or need the old one.
- **Testing the backup actually works**: target is a **separate** cluster, so
  you can compare against the still-running source without touching it.

**EBS volumes are Availability-Zone-locked.** `--az` is always required for
the same reason `--target-cluster` is: get it wrong and the restore creates a
volume in an AZ with no node to attach it to, and the pod sits
`Pending`/`FailedScheduling` forever. Find the target cluster's AZ with:
```bash
kubectl get nodes -o jsonpath='{.items[0].metadata.labels.topology\.kubernetes\.io/zone}'
```

**"Restore workflow failed due to an internal error" on the EKS part of a
restore job is common and often meaningless.** Across repeated testing, this
exact message showed up on the EKS (cluster-state) nested job on *every
single restore*, including ones where everything restored perfectly. AWS's
own docs note that EKS restores silently skip certain auto-regenerated
objects (`Endpoints`, `EndpointSlices`, `CSINodes`, `VolumeAttachments` —
things Kubernetes recreates on its own) and that can surface as this generic
message even when nothing meaningful is actually missing. **Never trust this
message alone in either direction** — always confirm with `verify-restore.sh`
(and for databases, an actual row-level check — see "Verifying data, not just
pods" below) rather than reading the one-line status as a verdict.

**A snapshot restore is point-in-time, not live-synced.** If you restore from
last night's backup, you'll have *less* data than the live source has right
now — that's correct behavior, not data loss. Anything written to the source
after the backup ran can't possibly be in that recovery point.

**Known gap: cleaning up a restored environment isn't just "delete the
namespace."** When AWS Backup restores a PV, the new EBS volume it creates is
**untagged**. The EBS CSI driver's own IAM policy only grants it
`ec2:DeleteVolume` on volumes carrying specific tags it stamps on volumes it
provisions itself — so a restored volume can never be cleanly deleted by the
CSI driver once its PVC is removed. It'll sit stuck in `Released` phase
forever, and the real EBS volume keeps costing money until you manually
delete it. See "Cleaning up after a restore test" below for the exact
recovery steps if you hit this.

**Known gap: restore-job email notifications don't currently fire.** The
`backup` module's EventBridge rule for *backup* job notifications is
confirmed working. The rule for *restore* job notifications has been
confirmed **not** to fire (checked via `AWS/Events` CloudWatch metrics — zero
invocations despite a completed restore job) — the assumed event field
(`detail.resourceType: "EKS"`) likely doesn't match what AWS actually sends
for a composite restore job. Until this is fixed in `modules/backup/main.tf`,
**you will not get an email for a restore succeeding or failing** — always
check manually with `restore-status.sh`.

## The scripts

| Script | What it does |
|---|---|
| `trigger-backup.sh` | Starts an on-demand backup of this environment's cluster, instead of waiting for the next scheduled run. |
| `backup-status.sh <job-id> [--watch]` | Checks a backup job's status. |
| `list-recovery-points.sh [--latest]` | Lists this environment's composite recovery points, newest first. |
| `trigger-restore.sh` | Starts a restore — full cluster or specific namespaces — from a recovery point into a target cluster. |
| `restore-status.sh <job-id> [--watch]` | Checks a restore job's status, including every nested per-volume child job in one view. |
| `verify-restore.sh [namespace ...]` | Checks pod/PVC health on whatever cluster your current `KUBECONFIG` points at. No arguments = every namespace. |

Every script has a `-h`/`--help` that prints its own usage (just the comment
header at the top of the file).

## Walkthrough: trigger a backup, restore it, verify it

This mirrors the actual end-to-end test this toolkit was built and validated
against.

### 1. Trigger a backup

```bash
cd <env>/aws-backup-scripts
export AWS_PROFILE=<your-profile>
./trigger-backup.sh
# -> { "BackupJobId": "..." }
./backup-status.sh <BackupJobId> --watch
```

Use `--dry-run` first if you want to see the exact `aws backup start-backup-job`
command without running it.

### 2. Find the recovery point

```bash
./list-recovery-points.sh            # see all of them
./list-recovery-points.sh --latest   # just the newest ARN
```

`trigger-restore.sh` uses the latest one automatically if you don't pass
`--recovery-point-arn` — you only need this step if you want a *specific*
day's backup instead.

### 3. Restore it

Figure out your target cluster's AZ first (see "Concepts" above), then:

```bash
# Full cluster
./trigger-restore.sh --target-cluster <name> --az <az>

# Just specific namespaces (up to 5) -- needs the SOURCE cluster's kubeconfig
# to look up which PVs actually belong to those namespaces (AWS Backup's own
# recovery-point metadata only exposes PV names, never which namespace they
# were in)
export KUBECONFIG=/path/to/source-cluster-kubeconfig.yaml
./trigger-restore.sh --target-cluster <name> --az <az> --namespaces common-services,monitoring
```

Both print the exact `aws backup start-restore-job` command before running it
and return a `RestoreJobId`. Add `--dry-run` to preview without executing.

### 4. Track it

```bash
./restore-status.sh <RestoreJobId> --watch
```

Shows the parent job plus every nested EBS/EKS child job, same detail as the
console's "Nested restore jobs" table, polling until it's done.

### 5. Verify it actually worked

```bash
export KUBECONFIG=/path/to/target-cluster-kubeconfig.yaml
./verify-restore.sh                           # every namespace
./verify-restore.sh common-services monitoring  # just the ones you restored
```

Flags anything not `Running`/ready, any PVC not `Bound`, and (only for
namespaces with an actual problem) the last 10 Warning events in that
namespace so you don't have to go hunting.

### Verifying data, not just pods

`verify-restore.sh` proves pods are healthy and PVCs are bound — it does
**not** prove the data inside a database is real and complete. For that,
compare actual row counts between source and target. Two things to know
before you do:

- **Don't trust `pg_stat_user_tables.n_live_tup`** for this. It's a
  statistics-collector *estimate*, and it reads as `0` or stale immediately
  after a cold start from a restored volume, even when the real data is
  there. Run an actual `SELECT count(*) FROM <table>` instead.
- **A row-count difference between source and target is expected, not a
  bug**, if the source has kept running since the backup was taken — see
  "Concepts" above. To prove it, filter by a timestamp column against the
  recovery point's creation time: rows created *before* the backup should
  match almost exactly between source and target; the "missing" ones on the
  target should all have been created *after* the backup ran.

```bash
PGPASSWORD=$(kubectl exec -n <ns> <postgres-pod> -- cat /opt/bitnami/postgresql/secrets/postgres-password) \
  kubectl exec -n <ns> <postgres-pod> -- bash -c \
  'PGPASSWORD='"$PGPASSWORD"' psql -U postgres -d <db> -c "SELECT count(*) FROM <table>;"'
```

(Adjust the secrets path if the Postgres image/chart differs — this is the
Bitnami PostgreSQL layout used by `common-services`.)

## Cleaning up after a restore test

**Deleting a restored namespace does not fully clean up.** Because of the
untagged-volume gap described in "Concepts," any PV whose PVC you delete will
get stuck in `Released` phase forever, and its real EBS volume keeps costing
money. After deleting a namespace on a test/throwaway target cluster:

```bash
# 1. Confirm the namespace actually finished deleting -- if it hangs in
#    Terminating, check for a dangling APIService (metrics-server living in
#    the deleted namespace is the most common cause):
kubectl get apiservices | grep -v True
kubectl delete apiservice <the broken one>   # safe -- it's just a stale pointer

# 2. Check for PVs stuck in Released phase
kubectl get pv

# 3. For each one, confirm the volume is genuinely orphaned (not attached
#    anywhere), then delete it for real in AWS -- this is the step the CSI
#    driver can't do itself
aws ec2 describe-volumes --volume-ids <id> --query 'Volumes[0].{State:State,Attachments:Attachments[0].State}'
aws ec2 delete-volume --volume-id <id>

# 4. Only after the real volume is confirmed gone, remove the now-inert PV
#    object's finalizers so Kubernetes actually deletes it
kubectl patch pv <name> -p '{"metadata":{"finalizers":null}}' --type=merge
```

Do **not** skip straight to step 4 without doing steps 2–3 first — removing a
PV's finalizer before the real volume is deleted orphans it with nothing left
to track it.

## Also useful: `cleanup_all_services`

If the target cluster has the full app stack deployed (not just raw restored
Kubernetes objects), `<env>/install.sh cleanup_all_services` is the repo's
own proper teardown (uninstalls Helm releases, removes cert-manager's
cluster-scoped CRDs/webhooks that a plain namespace delete leaves behind).
It operates at the same namespace-deletion level as a manual `kubectl delete
ns`, though — it won't resolve the stuck-PV issue above either; you'll still
need the manual volume cleanup afterward.

## Troubleshooting

| Symptom | What it usually means |
|---|---|
| Composite recovery point has only the cluster-state child, no PV children | The backup silently didn't capture volume data — check the source cluster's default StorageClass is CSI-backed (`ebs.csi.aws.com`), not the legacy in-tree `kubernetes.io/aws-ebs` plugin. |
| `AccessDenied: iam:PassRole` when triggering a restore | The account's IAM policy for your role doesn't allow passing the restore role to `backup.amazonaws.com`. Account-admin fix, not something in this repo. |
| `FailedScheduling: ... bound to non-existent persistentvolume ... not found` after a restore | The PVC restored, but its PV didn't (or a stale PV with the same name from an earlier test is blocking it — see "Cleaning up" above). |
| Restored pods crash-looping across multiple namespaces (Keycloak, aggregator, signals all failing startup probes) | Usually a **cascade** from one real problem (commonly Postgres/Redis not binding), not independent bugs — fix the root PV/PVC issue first and recheck. |
| Namespace stuck in `Terminating` | Check `kubectl get namespace <ns> -o jsonpath='{.status.conditions}'` — it names the exact blocker. A dangling `metrics.k8s.io` APIService (from a deleted `metrics-server`) is the most common cause and is safe to delete directly. |
| No email for a backup/restore event | Confirm your SNS subscription is actually confirmed (`aws sns list-subscriptions-by-topic --topic-arn ...` — look for a real `SubscriptionArn`, not absent/pending). If it is confirmed and it's a *restore* job specifically, see the known EventBridge gap in "Concepts." |

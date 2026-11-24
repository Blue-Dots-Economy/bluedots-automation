# s3-export

A CronJob that dumps the Signals data (users, items, item actions) and the
aggregator organisation list to S3 as
gzipped NDJSON, using the existing `adhoc-scripts/signals-s3-export` image. The
aggregator's `GET /v1/campaign/dump` hands out signed links to these files.

Each run overwrites one object per table:

```
s3://<global.s3.bucket>/[<prefix>/]<network>/<instance id>/user.ndjson.gz
                                                            items.ndjson.gz
                                                            item_actions.ndjson.gz
                                                            aggregators.ndjson.gz
```

It is a separate release (`s3-export`, in its own `s3-export` namespace), deployed only by
`bash install.sh deploy_s3_exporter`. `deploy_all_services` does not run it.

## Where the settings come from

Like every other chart, from the env's global files, under `s3-export:`:

| File | Key | What |
|---|---|---|
| `global-values.yaml` | `_s3_export_enabled` | On/off. Off renders nothing. |
| `global-values.yaml` | `s3-export.instances` | Instance id (`_campaign_manager_instance_id`), network, schedule |
| `global-images.yaml` | `s3-export.image.tag` | Exporter image tag |
| `global-cloud-values.yaml` (generated) | `s3-export.serviceAccount` | `app_sa` role ARN (IRSA) |
| `global-cloud-values.yaml` (generated) | `global.s3.bucket` / `.region` | The app bucket |
| `global-secrets.yaml` (generated) | `s3-export.databaseUrl` | Signals read-only URL (`campaign_manager_signals_ro`) |
| `global-secrets.yaml` (generated) | `s3-export.aggDatabaseUrl` | Aggregator read-only URL (`aggregator_export_ro`) |

## Before you turn it on

- **The aggregator must have migration 0032 (release `202610-s1-rc2` or later).**
  The export reads `organisations` (renamed from `aggregator_orgs` in 0028) and its
  `parent_id`, `depth` and `known_as` columns (0028 and 0032). On an older aggregator
  the bootstrap grant is skipped and every run fails validation and writes nothing.
  Keep `_s3_export_enabled: false` until that release is deployed, then re-run
  `deploy_common_services` so the grant picks up the new columns.
- **Serving the files needs `GET /v1/campaign/dump` in the same aggregator release.**
  Releases up to `202609-*` have the route but not migration 0032; `202610-s1-rc2`
  to `rc5` have 0032 but the route was removed (aggregator-dpg#900). aggregator-dpg#1102
  restores it on `develop`, so the first aggregator release cut after it is the first
  that works end to end. Until then the export writes files that nothing hands out.
- **Switching over from the old exporter.** Older releases ran the exporter inside the
  signals chart (`helm/signals/charts/s3-export`). The next `deploy_signals` from this
  version removes it, and nothing replaces it until you run `deploy_s3_exporter`. Run
  both in the same window. Never run the old and new exporter against the same
  bucket keys at the same time.
- **Keycloak.** `/v1/campaign/dump` needs the `campaign-manager` client's service
  account. Run `deploy_keycloak` first; its init Job turns the service account on in an
  existing realm.

## Deploy

1. In `<env>/global-values.yaml`, set `_s3_export_enabled: true` and make sure
   `_campaign_manager_instance_id` is set. Also confirm that
   `system:serviceaccount:s3-export:signals-s3-export` is listed in
   `global.service_account_subjects`.
2. Apply the role change, then regenerate the generated files, from the env dir:
   `bash install.sh apply_tf_iam`, `bash install.sh apply_tf_random_passwords`,
   `bash install.sh apply_tf_output_file`.
3. Run `S3E_GHCR_USER=<github user> S3E_GHCR_PAT=<read:packages token> bash install.sh deploy_s3_exporter`.
   The image is private, so the function first creates its own pull secret,
   `s3-export-pull`, in the `s3-export` namespace. It doesn't use `ghcr-pull`. Without
   `S3E_GHCR_PAT` it keeps an existing `s3-export-pull`, or prompts for the token.
   `S3E_GHCR_USER` is required whenever the secret is created; there is no default.

To run it once without waiting for the schedule:

```bash
kubectl -n s3-export create job s3-export-manual --from=cronjob/s3-export-<instance-id>
kubectl -n s3-export logs -f job/s3-export-manual
```

The CronJob name uses the instance id with `_` turned into `-`.

## Aggregator `/v1/campaign/dump`

The aggregator api reads the dump with its own `app_sa` access, so it needs no new
permission. `global.campaignDumpInstanceId` and `global.campaignDumpPrefix` must
match this release's instance id and `s3.prefix` (both empty by default). The route
accepts only a token from the `campaign-manager` client's service account. The realm
ships it enabled, `apply-realm-config.py` enables it on an existing realm, and
`scripts/assert-realm.sh` fails CI if it is turned off.

The exporter writes with the aggregator's `app_sa` role, which has full read, write
and delete access to the app bucket. That is broader than it needs and is meant to be
temporary.

## Aggregator data

`aggregators.ndjson.gz` has one row per coordinator of each approved aggregator
organisation, with the organisation's parent, depth and known-as name. It needs an
image built from Blue-Dots-Economy/adhoc-scripts#27 or later (`sha-92956aa`), which
reads the `organisations` and `users` tables. The read-only role
`aggregator_export_ro` gets the columns it needs from the common-services bootstrap.
Re-run `deploy_common_services` once after the aggregator migrations. A missing grant
or an older image stops the whole run at validation, Signals included.

`registration_links.ndjson.gz` has one row per registration link (QR code), with its
full `registration_url`, and `aggregators` has the coordinator's masked name. Both
need an image built from Blue-Dots-Economy/adhoc-scripts#29 or later, plus the
`users`, `contact (id, name)` and `registration_links` grants from the same bootstrap.
The URL base is `s3-export.export.publicLinkBaseUrl`, or `https://<global.publicHost>`
when that is empty; the run stops if neither is set. The aggregator serves the file
through `/v1/campaign/dump` once it is in `global.campaignDumpFiles`.

## Remove

```bash
helm uninstall s3-export -n s3-export
kubectl -n s3-export delete secret s3-export-pull
```

The objects already in S3 stay until they are deleted.

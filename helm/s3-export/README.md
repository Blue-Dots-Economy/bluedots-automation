# s3-export (temporary)

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

## Deploy

1. In `<env>/global-values.yaml`, set `_s3_export_enabled: true` and make sure
   `_campaign_manager_instance_id` is set. Also confirm that
   `system:serviceaccount:s3-export:signals-s3-export` is listed in
   `global.service_account_subjects`.
2. Apply the role change, then regenerate the generated files, from the env dir:
   `bash install.sh apply_tf_iam`, `bash install.sh apply_tf_random_passwords`,
   `bash install.sh apply_tf_output_file`.
3. Run `S3E_GHCR_PAT=<read:packages token> bash install.sh deploy_s3_exporter`.
   The image is private, so the function first creates its own pull secret,
   `s3-export-pull`, in the `s3-export` namespace. It doesn't use `ghcr-pull`. Without
   `S3E_GHCR_PAT` it keeps an existing `s3-export-pull`, or prompts for the token.

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
accepts only a token from the `campaign-manager` client's service account, which
the shared realm must have enabled.

## Aggregator data

`aggregators.ndjson.gz` has one row per coordinator of each approved aggregator
organisation, with the organisation's parent, depth and known-as name. It needs an
image built from Blue-Dots-Economy/adhoc-scripts#27 or later (`sha-92956aa`), which
reads the `organisations` and `users` tables. The read-only role
`aggregator_export_ro` gets the columns it needs from the common-services bootstrap.
Re-run `deploy_common_services` once after the aggregator migrations. A missing grant
or an older image stops the whole run at validation, Signals included.

## Remove

```bash
helm uninstall s3-export -n s3-export
kubectl -n s3-export delete secret s3-export-pull
```

The objects already in S3 stay until they are deleted.

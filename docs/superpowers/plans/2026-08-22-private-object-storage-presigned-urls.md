# Private object storage with pre-signed URLs — infrastructure plan

**Date:** 2026-08-22
**Status:** proposed
**Scope:** `opentofu/aws/modules/{storage,iam,output-file}`, `opentofu/aws/_common/storage.hcl`,
`opentofu/aws/template/global-values.yaml`, `helm/aggregator/**`
**Sibling PRs:** `aggregator-dpg` (app-side TTL + key namespace) · `bluedots-infra-deployments` (per-env flip + object copy)
**Not affected:** `signals-dpg` — no object-storage code path exists in that repo.

## 1. The hole

`opentofu/aws/modules/storage/main.tf` treats `type = "public"` as "switch off every guard":

- **`:50`–`:59`** — `aws_s3_bucket_public_access_block` sets `block_public_acls`,
  `block_public_policy`, `ignore_public_acls` and `restrict_public_buckets` to
  `each.value.type == "private"`. For a public bucket all four are **`false`**.
- **`:108`–`:123`** — the bucket policy gains `PublicReadGetObject`: `Effect: Allow`,
  `Principal: "*"`, `Action: s3:GetObject` on `arn/*`, conditioned only on
  `StringLike { aws:Referer }` when `var.allowed_referers` is non-empty.

`aws:Referer` is a request header. Any client can send it. `variables.tf:49`–`:56` says so in its own
description ("clients can spoof the header"). So the effective access control on that bucket is:
**none**.

`_common/storage.hcl:32`–`:41` defaults `buckets` to one `public` and one `private` bucket, and
`opentofu/aws/template/global-values.yaml:192`–`:206` ships `public` enabled with `private` commented
out. Then `modules/output-file/global-cloud-values.yaml.tfpl:11` wires the application to it:

```yaml
global:
  s3:
    bucket: ${storage_bucket_public}
```

…which lands in `helm/aggregator/templates/configmap-global.yaml:28` as `S3_BUCKET`. And
`modules/iam/main.tf:45`–`:67` grants the app role `GetObject/PutObject/DeleteObject/ListBucket` on
`var.storage_bucket_public` only — the private bucket isn't even reachable by the app today.

Net effect, in every environment: the aggregator writes raw participant CSVs (name, phone, full
profile), error CSVs, and QR PNGs into a bucket the internet can read.

There are also **no lifecycle rules anywhere in the module** — no `aws_s3_bucket_lifecycle_configuration`
resource exists. Nothing has ever expired. `aggregator-dpg`'s
`apps/worker/src/jobs/cron-watchdog.ts:11` documents an assumption that "S3 lifecycle (raw CSVs +
errors.csv) is configured externally on the bucket". That external configuration does not exist.

## 2. Target state

One bucket per environment for aggregator objects, **`type = "private"`**, with:

1. All four `block_public_*` flags `true`.
2. No `PublicReadGetObject` statement. `DenyInsecureTransport` (already present, `main.tf:94`–`:106`)
   retained for all buckets.
3. **CORS enabled** — required, see §3.2.
4. Lifecycle rules expiring transient prefixes, with retention configurable per environment.
5. App IAM scoped to this bucket.

All browser reads and writes go through pre-signed URLs minted by `aggregator-api` after it has
authorized the caller. No object is ever reachable without a signature.

## 3. Changes

### 3.1 Retire `type = "public"` rather than reconfigure it

Deleting the `PublicReadGetObject` branch and leaving `type = "public"` accepted would leave a
`type` value whose only remaining effect is *turning off the public-access block* — a footgun that
reads as harmless. Instead:

- `modules/storage/variables.tf` — restrict `buckets[*].type` to `["private"]` in the existing
  validation block, with an error message that names this document.
- `modules/storage/main.tf:55`–`:58` — hardcode all four `block_public_*` to `true`.
- `modules/storage/main.tf:108`–`:123` — delete the `PublicReadGetObject` concat branch; the policy
  becomes `DenyInsecureTransport` only.
- Remove `var.allowed_referers` and its plumbing in `_common/storage.hcl:13`, `:28`. It exists solely
  to scope a public-read policy that no longer exists. Leaving a dead "security" knob in place
  invites someone to re-enable the thing it was scoping.
- Keep `storage_bucket_public*` outputs as **deprecated aliases** for exactly one release so a
  half-applied environment doesn't fail on a missing output; mark them for deletion in the follow-up.

`tofu validate` will fail loudly for any environment still declaring `type: public` — which is the
intended forcing function, and why the infra-deployments PR must land in the same window.

### 3.2 CORS is now mandatory, not optional

This is the failure mode most likely to be missed. A browser doing a pre-signed `PUT` sends a
cross-origin request to `*.s3.<region>.amazonaws.com`, so the bucket needs a CORS rule or the
preflight fails and every upload breaks — with an error that looks nothing like a permissions
problem.

Today `cors_enabled: true` is set on the **public** bucket and the commented-out `private` template
(`global-values.yaml:206`–`:208`) has only `versioning_enabled: true`. Anyone who migrates by
uncommenting that block gets a working-looking deploy with broken uploads.

- `modules/storage/variables.tf` — default `cors_enabled` to **`true`**.
- `modules/storage/main.tf:136`–`:150` — unchanged logic, but note that
  `local.effective_cors_origins` (`:23`–`:25`) currently falls back to `allowed_referers` stripped of
  its path glob. With `allowed_referers` removed, `cors_allowed_origins` becomes the sole source, so
  `_common/storage.hcl:12` must keep deriving it from `aggregator_host`. An environment with no
  `aggregator_host` gets **no CORS rule and therefore no working upload** — add a `precondition` that
  fails the plan rather than shipping that silently.
- `cors_allowed_methods` already defaults to `["GET","HEAD","PUT"]` (`variables.tf:37`–`:41`), which
  is exactly the presigned surface. `expose_headers = ["ETag"]` (`main.tf:147`) is required — the app
  captures the ETag via `headObject`.

### 3.3 Lifecycle rules with configurable retention

New resource `aws_s3_bucket_lifecycle_configuration` in `modules/storage/main.tf`, driven by a new
per-bucket `lifecycle_rules` field:

```hcl
buckets = {
  aggregator = {
    type               = "private"
    cors_enabled       = true
    versioning_enabled = true
    lifecycle_rules = {
      uploads_raw_retention_days    = 7    # uploads/raw/
      uploads_errors_retention_days = 30   # uploads/errors/
      legacy_bulk_retention_days    = 30   # bulk-uploads/  (pre-migration keys)
      abort_incomplete_mpu_days     = 1
    }
  }
}
```

Prefixes match the target key namespace in the `aggregator-dpg` doc. `qr/` is deliberately absent —
QR PNGs are durable; a printed QR outlives any retention window.

**Two rules that are easy to omit and make the whole feature a no-op:**

1. `noncurrent_version_expiration` on every transient rule. The bucket has
   `versioning_enabled = true`, so a plain `expiration` block writes a delete marker and keeps the
   PII in a noncurrent version **forever**. Each rule needs both.
2. `abort_incomplete_multipart_upload` — abandoned browser PUTs leave parts that are billable and
   invisible to `ListObjects`.

A retention value of `0` or unset must mean "no rule for this prefix", not "expire immediately".
Guard it in a validation block; the inverse reading deletes production data on first apply.

### 3.4 Point the application at the private bucket

- `modules/output-file/global-cloud-values.yaml.tfpl:11` — `bucket: ${storage_bucket_private}`.
- `_common/output-file.hcl:123` and its `mock_outputs` (`:63`) — swap
  `storage_bucket_public` → `storage_bucket_private`.
- `modules/output-file/variables.tf` — rename the variable to match.
- `modules/iam/main.tf:61`–`:63` — scope the app role to `var.storage_bucket_private`.
  `modules/iam/variables.tf:26`–`:34` already declares **both** `storage_bucket_public` and
  `storage_bucket_private`; drop the public one.

The `signals-export` bucket and its write-only `signals_export_s3` role
(`modules/iam/main.tf:108`–`:129`) are already private and least-privilege. **No change.**

### 3.5 Plumb the signed-URL TTL through Helm

`BULK_UPLOAD_URL_TTL_SECONDS` and `QR_DOWNLOAD_URL_TTL_SECONDS` are **already** deployment-configurable
(`helm/aggregator/charts/api/templates/configmap.yaml:28`, `:30` from `.Values.bulk.*`). Two gaps
against the requirement:

1. Both default to **900s**, not the required 600s —
   `helm/aggregator/values.yaml:294`–`:297` and `helm/aggregator/charts/api/values.yaml:58`–`:61`.
2. There is no single canonical knob, and the worker configmap
   (`helm/aggregator/charts/worker/templates/configmap.yaml`) has no TTL at all.

Add under `global` in `helm/aggregator/values.yaml`, next to the existing `global.s3` block
(`:125`–`:129`):

```yaml
global:
  signedUrl:
    ttlSeconds: 600        # 10 minutes — canonical TTL for every pre-signed URL
```

Render `SIGNED_URL_TTL_SECONDS: "{{ .Values.global.signedUrl.ttlSeconds }}"` in
`helm/aggregator/templates/configmap-global.yaml` alongside the existing `S3_*` keys (`:26`–`:30`),
so api and worker both inherit it from the shared ConfigMap rather than duplicating it — matching how
`S3_REGION`/`S3_BUCKET` are already handled.

Keep `bulk.uploadUrlTtlSeconds` and `bulk.qrDownloadUrlTtlSeconds` as **optional overrides**, but
change their defaults to empty so the canonical value applies unless an environment deliberately
overrides. Rendering an empty string for a numeric env var must be avoided — guard with `if` in the
template rather than emitting `""`.

Surface it in `opentofu/aws/template/global-values.yaml` as
`global.signed_url_ttl_seconds: 600`, passed through `_common/output-file.hcl` into the generated
overlay, so a deployer sets it in one committed place.

### 3.6 `global-values.yaml` template

Replace the `buckets` block (`:192`–`:206`) with a single private aggregator bucket carrying
`cors_enabled: true`, `versioning_enabled: true` and the `lifecycle_rules` map from §3.3, keeping the
`signals-export` entry as-is. Update the comment at `:87`–`:89` — it currently says `aggregator_host`
feeds "CORS allowed origins" *and* the public-read referer scope; only the former survives.

## 4. Migration sequencing

The bucket name is `<building_block>-<environment>-<account_id>-<key>`, so renaming the logical key
from `public` to `aggregator` **creates a new bucket**. Objects must be copied before the flip.

| # | Step | Where | Reversible? |
|---|---|---|---|
| 1 | Merge this PR + the `aggregator-dpg` PR. No environment changes yet. | both repos | yes |
| 2 | Add the new private bucket **alongside** the existing public one, apply. Two buckets exist. | infra-deployments | yes |
| 3 | `aws s3 sync s3://<public> s3://<private>` — objects, not ACLs. | operator | yes |
| 4 | Regenerate + re-encrypt `global-cloud-values.yaml`; deploy aggregator api+worker. App now reads/writes the private bucket. | infra-deployments | **yes** — revert the overlay; the public bucket still holds every object |
| 5 | Verify: bulk upload end-to-end, `errors.csv` download, QR download, and an **unsigned** `curl` against a known key returns `403`. | operator | — |
| 6 | Empty and destroy the public bucket. | infra-deployments | **no** |

Step 4 is the cutover and it is reversible; step 6 is the point of no return and should trail step 5
by at least one full business day. Do not collapse 2–4 into one apply: that flips the app to an empty
bucket and every existing `errors.csv`/QR download 404s.

`helm lint` and `tofu validate -backend=false` run in CI (`.github/workflows/ci.yml`, path-filtered
to `helm/` and `opentofu/`) plus `install.sh lint` (`opentofu/aws/template/install.sh:563`) — those
cover template/module syntax but **not** the bucket policy semantics. Step 5's unsigned-`curl` check
is the only real verification that the bucket went private.

## 5. Follow-up required in `bluedots-infra-deployments`

Tracked in that repo's sibling PR; listed here because this repo owns the contract. Per environment
(`up-gzb-blue-dots-prod-cluster`, `Ontac-orange-dots-prod-cluster`, `Ekstep-blue-dots-dev-cluster`,
`Ekstep-purple-dots-dev-cluster`) — all four currently declare `buckets.public: {type: public}`:

- `global-values.yaml` — replace the `public` bucket with the private `aggregator` bucket
  (`cors_enabled: true`, `versioning_enabled: true`, `lifecycle_rules`), and add
  `global.signed_url_ttl_seconds: 600`.
- Confirm `global.aggregator_host` is set — without it there is no CORS rule and uploads break (§3.2).
- `global-cloud-values.yaml` — **generated and SOPS-encrypted.** Regenerate via the env's `tf.sh` /
  `install.sh` after step 2, then re-encrypt. Its `global.s3.bucket` (encrypted) must end up as the
  private bucket name. Do not hand-edit.
- No new secret material: the app uses IRSA (`app_sa_role_arn`), not static keys, so `secrets.yaml`
  is untouched.

## 6. Risks

| Risk | Mitigation |
|---|---|
| `lifecycle_rules` applied without `noncurrent_version_expiration` → nothing actually deletes | §3.3; assert both blocks render in review |
| Private bucket without CORS → all uploads fail preflight | §3.2 default + plan-time precondition |
| Retention `0`/unset read as "expire now" | validation block; explicit "no rule" semantics |
| Public bucket destroyed before verification | step 6 gated behind step 5, ≥1 day apart |
| An environment left on `type: public` | `tofu validate` fails closed; infra-deployments PR lands in the same window |
| Deprecated `storage_bucket_public` alias outlives its release | tracked as an explicit follow-up, not left implicit |

## 7. Open questions

1. **CloudFront + OAC** instead of direct pre-signed GETs for `qr/`? Stronger isolation and a stable
   URL for printed collateral, at the cost of a distribution per environment. `variables.tf:55`
   already gestures at this. Deferred — out of scope.
2. Should each aggregator get a prefix-scoped IAM condition, or is row-ownership at the API
   sufficient? Current design says the API is the authorization boundary and the prefix is only for
   grouping and lifecycle. Revisit if a third writer appears.
3. `signals-export` retention — that bucket has versioning and no lifecycle either. Same latent
   unbounded-growth issue, different data class (non-PII). Worth its own ticket.

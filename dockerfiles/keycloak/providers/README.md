# Keycloak provider jars

Everything in this directory is copied to `/opt/keycloak/providers/` by
`../Dockerfile` and indexed by `kc.sh build` at image build time.

## What is here

| Jar | Version | Source |
|-----|---------|--------|
| `keycloak-otp-1.2.0-SNAPSHOT.jar` | 1.2.0-SNAPSHOT | <https://github.com/Blue-Dots-Economy/keycloak-otp-authenticator> |

`sha256:05719f4e050e8a671100b6b822f83694890e8192bea67133b546eca6d3f64b0b`

> The source repo moved to the `Blue-Dots-Economy` org; the old
> `sanketika-labs` URL recorded here was stale. Note also that the SMS vendor
> providers live on the **`enhancements`** branch, not `main` — `main` carries
> no msg91 provider at all, so a jar built from it would break every cluster
> running `smsProvider: msg91`.

The jar is committed rather than fetched at build time so an image build is
reproducible from a checkout alone, with no dependency on a second private repo
being reachable from the runner.

### What it registers

`META-INF/services/org.keycloak.authentication.AuthenticatorFactory`:

- `hr.delmisoft.keycloak.otp.identifier.IdentifierFormAuthenticatorFactory` → **`otp-identifier-form`**
- `hr.delmisoft.keycloak.otp.OtpChannelChoiceAuthenticatorFactory` → **`otp-channel-choice-form`**
- `hr.delmisoft.keycloak.otp.EmailOtpAuthenticatorFactory`
- `hr.delmisoft.keycloak.otp.sms.SmsOtpAuthenticatorFactory`

Plus an SMS SPI (`hr.delmisoft.keycloak.otp.sms.SmsSpi`) configured at runtime
via `KC_SPI_SMS_PROVIDER` (`log` / `twilio` / `sns` / `msg91` / `http`) and the
matching credential env vars, which the chart wires from the release Secret.

### `http` — the preferred provider

`http` posts the OTP to **notification-service** rather than calling a vendor
from inside Keycloak. Prefer it: every SMS vendor after MSG91 then becomes an
NS-only change, instead of repeating this whole chain (Java PR → jar → image →
tag pin → chart values) per vendor. It also collapses the login-OTP template id,
which currently exists twice — `msg91TemplateId` here and
`SMS_LOGIN_OTP_TEMPLATE_ID` in NS.

Shipped in `1.2.0-SNAPSHOT` (`HttpSmsProviderFactory`).

It must send NS's HMAC envelope (`X-NS-Key`, `X-NS-Timestamp`, `X-NS-Nonce`,
`X-NS-Signature` over `METHOD\nPATH\nTIMESTAMP\nNONCE`) and a body of:

```json
{"channel":"sms","to":"+9190...","template_id":"login_otp",
 "priority":"realtime","variables":{"message":"123456"}}
```

No message text: `login_otp` is a template NS *names*, so NS owns both the
vendor's template id and the body. Env wired by the chart when
`smsProvider: http`: `SMS_HTTP_URL`, `SMS_HTTP_TEMPLATE_ID`,
`SMS_HTTP_OTP_VAR_NAME`, `SMS_HTTP_KEY_ID`, `SMS_HTTP_TIMEOUT_MS`, plus
`SMS_HTTP_SECRET` from the Secret.

The trade-off is that login OTP gains a hard dependency on notification-service
being reachable from `common-services`.

Only the OTP code is forwarded, never the rendered SMS text. Under Indian DLT
the delivered copy must match the template registered with the operator, so
notification-service holds the authoritative text and the string Keycloak's
theme renders is discarded.

> Setting `smsProvider: http` on an image built from a jar older than
> `1.2.0-SNAPSHOT` fails at **session-factory init** — the pod CrashLoopBackOffs
> on an unknown SPI provider id. It is not a realm-import failure, so look in
> the container log rather than the realm-init Job. Either way it does not
> silently degrade to another vendor.
>
> **Pin an immutable image tag before flipping the value.** The chart defaults to
> `image.tag: develop` with `pullPolicy: IfNotPresent`, so a node holding a
> cached `develop` layer keeps serving the OLD jar even after the config change
> rolls the pods — the flip then looks applied and is not. Publish a
> `sha-xxxxxxx` tag and set it in `<env>/global-images.yaml`, or set
> `pullPolicy: Always` for the cutover.

The two **bolded** provider ids are referenced by name in
`helm/keycloak/charts/keycloak/files/realm.json` and asserted by
`helm/keycloak/files/apply-portal-gate.py`. If this jar is missing or fails to
load, realm import and the gate Job both fail on unknown provider ids — they do
not silently degrade to password login.

## Only one jar per provider

Keycloak loads **every** jar in this directory. Two versions of the same jar
means two factories registering the same provider id, resolved by classloader
order. When bumping, **replace** the old jar — never leave both.

## Bumping the version

```bash
# 1. Build the jar from its own repo (Java 17+, uses the bundled wrapper).
#    Build from `enhancements`, NOT `main` — see the note above.
git clone https://github.com/Blue-Dots-Economy/keycloak-otp-authenticator
cd keycloak-otp-authenticator && git switch enhancements
./mvnw clean package -DskipTests
# NOTE: the jar committed here is built from Blue-Dots-Economy/keycloak-otp-authenticator#1,
# which adds HttpSmsProviderFactory and is not yet merged into `enhancements`.
# Until it is, `git switch enhancements` reproduces a jar WITHOUT the http
# provider and a sha256 that does not match the file here. Check out the PR
# branch (`feat/http-sms-provider`) to reproduce this artefact exactly.

# 2. Replace the jar here (delete the old one — see above)
rm dockerfiles/keycloak/providers/keycloak-otp-*.jar
cp dist/target/keycloak-otp-<version>.jar dockerfiles/keycloak/providers/

# 3. Update the table + sha256 above
shasum -a 256 dockerfiles/keycloak/providers/keycloak-otp-<version>.jar

# 4. Publish the image, then pin the new tag in the target environment's
#    opentofu/aws/<env>/global-images.yaml → keycloak.image.tag
#    (Actions → "Build Keycloak image" → workflow_dispatch)
```

Then verify against a live deployment before promoting:

```bash
kubectl -n common-services logs deploy/keycloak-keycloak | grep -i 'otp\|provider'
# and confirm the flow still resolves:
bash scripts/assert-realm.sh
```

## Relationship to the app repos

`aggregator-dpg/infra/keycloak/providers/` and
`signals-dpg/infra/keycloak/providers/` keep their own copies of this jar for
**local dev only** — their compose stacks run the stock Keycloak image with the
directory bind-mounted and `start-dev`, which re-indexes providers on every boot.
Those trees are developer-local and are not upstream of this one; the same
relationship `scripts/build-realm.sh` documents for the realm JSON.

They currently sit on **1.0.0-SNAPSHOT** while this directory ships
**1.2.0-SNAPSHOT**. Bumping them is a separate change in those repos and is not
required for a deployment — but note the 1.0.0 jar has no `http` provider, so
local dev cannot exercise the notification-service path until it is bumped.

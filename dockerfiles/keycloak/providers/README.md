# Keycloak provider jars

Everything in this directory is copied to `/opt/keycloak/providers/` by
`../Dockerfile` and indexed by `kc.sh build` at image build time.

## What is here

| Jar | Version | Source |
|-----|---------|--------|
| `keycloak-otp-1.2.0-SNAPSHOT.jar` | 1.2.0-SNAPSHOT | <https://github.com/Blue-Dots-Economy/keycloak-otp-authenticator> |

`sha256:05719f4e050e8a671100b6b822f83694890e8192bea67133b546eca6d3f64b0b`

> The hash identifies the **committed file**, not a target to reproduce: a jar
> is a zip and carries build timestamps, so a fresh `mvn package` of the same
> source yields different bytes. Use it to verify what is in this directory,
> and update it whenever the jar is replaced.

> The source repo is in the `Blue-Dots-Economy` org. Build from **`main`**: it
> carries every SMS vendor provider (`log`, `twilio`, `sns`, `msg91`, `http`)
> and both email OTP transports.

The jar is committed rather than fetched at build time so an image build is
reproducible from a checkout alone, with no dependency on a second private repo
being reachable from the runner.

### What it registers

`META-INF/services/org.keycloak.authentication.AuthenticatorFactory`:

- `hr.delmisoft.keycloak.otp.identifier.IdentifierFormAuthenticatorFactory` → **`otp-identifier-form`**
- `hr.delmisoft.keycloak.otp.OtpChannelChoiceAuthenticatorFactory` → **`otp-channel-choice-form`**
- `hr.delmisoft.keycloak.otp.EmailOtpAuthenticatorFactory`
- `hr.delmisoft.keycloak.otp.sms.SmsOtpAuthenticatorFactory`

Plus two SPIs, each selected at runtime by the chart:

- **SMS** (`hr.delmisoft.keycloak.otp.sms.SmsSpi`, SPI id `sms`): selected by
  `KC_SPI_SMS_PROVIDER` (`log` / `twilio` / `sns` / `msg91` / `http`), with the
  matching credential env vars the chart wires from the release Secret. Chart
  value `smsProvider`.
- **Email OTP** (`hr.delmisoft.keycloak.otp.email.OtpEmailSenderSpi`, SPI id
  `otp-email`): `smtp` (the realm's SMTP server, the default by provider order)
  or `http` (notification-service). Selected by `KC_SPI_OTP_EMAIL__PROVIDER`,
  with a double underscore, the current SPI option format. Chart value
  `otpEmailProvider`; the chart renders the env only for `http`. Ships in the
  jar built from `main` after Plan F3 (the jar committed here predates it).

`META-INF/services/org.keycloak.protocol.oidc.grants.OAuth2GrantTypeFactory`
adds the `urn:otp:email` and `urn:otp:sms` direct grants.

### `http` — the preferred provider

`http` posts the OTP to **notification-service** rather than calling a vendor
(or an SMTP server) from inside Keycloak. Both SPIs have one, and they share one
NS connection. Prefer it: every SMS vendor after MSG91 then becomes an
NS-only change, instead of repeating this whole chain (Java PR → jar → image →
tag pin → chart values) per vendor. It also collapses the login-OTP template id,
which currently exists twice — `msg91TemplateId` here and
`SMS_LOGIN_OTP_TEMPLATE_ID` in NS.

The jar built from `main` after Plan F3 posts to **`/v1/notify`** with **HMAC
v2**, which is what the chart's default `SMS_HTTP_URL` targets. (The
`1.2.0-SNAPSHOT` jar committed here posts to the legacy `/notify` with HMAC v1;
replace it before setting either transport to `http` — see "Bumping the
version".)

Each request carries NS's HMAC v2 envelope: `X-NS-Key`, `X-NS-Timestamp`,
`X-NS-Nonce` and `X-NS-Signature: v2=<hex>`, an HMAC-SHA256 over
`METHOD\nPATH\nTIMESTAMP\nNONCE\nsha256(body)` (the path includes any query; a
fresh nonce per request). The body names a template:

```json
{"template_key":"login_otp","channel":"sms","to":{"phone":"+9190..."},
 "variables":{"message":"123456"},"priority":"urgent"}
{"template_key":"login_otp","channel":"email","to":{"email":"user@example.org"},
 "variables":{"message":"123456"},"priority":"urgent"}
```

No message text: `login_otp` is a template NS *names*, so NS owns the vendor's
template id, the SMS body and the email subject and body (the email template
comes from the cluster's NS catalogue). Env wired by the chart when
`smsProvider` or `otpEmailProvider` is `http`: `SMS_HTTP_URL`,
`SMS_HTTP_KEY_ID`, `SMS_HTTP_TIMEOUT_MS` (shared), `SMS_HTTP_TEMPLATE_ID`,
`SMS_HTTP_OTP_VAR_NAME` (SMS), plus `SMS_HTTP_SECRET` from the Secret. Email
reads `OTP_EMAIL_HTTP_TEMPLATE_ID` (default `login_otp`) and
`OTP_EMAIL_HTTP_OTP_VAR_NAME` (default `message`); the defaults match the
catalogue, so the chart sets neither.

The trade-off is that login OTP gains a hard dependency on notification-service
being reachable from `common-services`.

Only the OTP code is forwarded, never the rendered SMS text. Under Indian DLT
the delivered copy must match the template registered with the operator, so
notification-service holds the authoritative text and the string Keycloak's
theme renders is discarded.

> Setting `smsProvider: http` on an image built from a jar older than
> `1.2.0-SNAPSHOT`, or `otpEmailProvider: http` on one older than the Plan F3
> jar, fails at **session-factory init** — the pod CrashLoopBackOffs
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
# 1. Build the jar from its own repo's `main` (Java 17+, uses the bundled
#    wrapper). Its pom's keycloak.version tracks the runtime in ../Dockerfile.
git clone https://github.com/Blue-Dots-Economy/keycloak-otp-authenticator
cd keycloak-otp-authenticator && git switch main
./mvnw clean package -DskipTests

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

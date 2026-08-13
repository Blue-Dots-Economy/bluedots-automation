# Keycloak provider jars

Everything in this directory is copied to `/opt/keycloak/providers/` by
`../Dockerfile` and indexed by `kc.sh build` at image build time.

## What is here

| Jar | Version | Source |
|-----|---------|--------|
| `keycloak-otp-1.1.0-SNAPSHOT.jar` | 1.1.0-SNAPSHOT | <https://github.com/sanketika-labs/keycloak-otp-authenticator> |

`sha256:418cba6d9fb783bfe8f52df16cee01f5e80fda7a26b91352ac2c5457aa68295f`

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
via `KC_SPI_SMS_PROVIDER` (`log` / `twilio` / `sns` / `msg91`) and the matching
credential env vars, which the chart wires from the release Secret.

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
# 1. Build the jar from its own repo (Java 17+, uses the bundled wrapper)
git clone https://github.com/sanketika-labs/keycloak-otp-authenticator
cd keycloak-otp-authenticator && ./mvnw clean package -DskipTests

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
**1.1.0-SNAPSHOT**. Bumping them is a separate change in those repos and is not
required for a deployment.

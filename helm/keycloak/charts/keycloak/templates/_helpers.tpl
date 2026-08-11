{{- define "keycloak.fullname" -}}
{{- printf "%s-keycloak" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "keycloak.releaseFullname" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "keycloak.secretName" -}}
{{- $existing := default "" .Values.global.existingSecret -}}
{{- if $existing -}}
{{- $existing -}}
{{- else -}}
{{- printf "%s-secrets" (include "keycloak.releaseFullname" .) -}}
{{- end -}}
{{- end -}}

{{- define "keycloak.globalConfigMap" -}}
{{- printf "%s-global" (include "keycloak.releaseFullname" .) -}}
{{- end -}}

{{- define "keycloak.envConfigMap" -}}
{{- printf "%s-keycloak" (include "keycloak.releaseFullname" .) -}}
{{- end -}}

{{- define "keycloak.realmConfigMap" -}}
{{- printf "%s-keycloak-realm" (include "keycloak.releaseFullname" .) -}}
{{- end -}}

{{- define "keycloak.renderScriptConfigMap" -}}
{{- printf "%s-keycloak-render" (include "keycloak.releaseFullname" .) -}}
{{- end -}}

{{- /*
Keycloak is a shared common service now, not part of aggregator-dpg, so the
labels say so.

NOTE: selectorLabels change with this move, and a Deployment's selector is
IMMUTABLE. That is safe here only because this ships as a NEW release
(`keycloak`) rather than an upgrade of the aggregator release. Never attempt to
upgrade the old aggregator-owned Keycloak into this chart — deploy fresh, verify,
then remove the old one.
*/ -}}
{{- define "keycloak.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: common-services
app.kubernetes.io/name: keycloak
app.kubernetes.io/component: keycloak
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end -}}

{{- define "keycloak.selectorLabels" -}}
app.kubernetes.io/name: keycloak
app.kubernetes.io/component: keycloak
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- /*
The realm name, resolved once for the whole subchart — KC config, the realm
render, and the Kong login rate-limit path.

Order: subchart `realm` (escape hatch) then `global.keycloakRealm`. REQUIRED,
with no literal default: a hardcoded fallback is precisely how the login
rate-limit path silently stopped matching any route once the realm was no longer
called `aggregator` (plan §4.3). Failing the render is the correct behaviour.
*/ -}}
{{- define "keycloak.realm" -}}
{{- $r := .Values.realm | default .Values.global.keycloakRealm -}}
{{- required "keycloak: realm name is required — set global.keycloakRealm (per-instance, no literal default)" $r -}}
{{- end -}}

{{- /*
Comma-separated list of signals-UI origins, for the shared realm's signals-ui
client allow-lists.

WHY THIS IS NOT global.publicHost: Keycloak is served on the aggregator host, but
the signals UI is served on its OWN hostname(s) — `global.publicHosts` is a LIST.
The realm ships __PUBLIC_BASE_URL__ on signals-ui, which resolves to the KEYCLOAK
host; using that in production means the OIDC redirect back to the signals UI does
not match its allow-list and login fails with invalid_redirect_uri. It only works
in local dev because both sides are localhost.

`signalsOrigins` overrides; otherwise derive from global.publicHosts. Empty is
allowed (signals not deployed) — render-realm.sh warns and keeps the fallback.
*/ -}}
{{- define "keycloak.signalsOrigins" -}}
{{- if .Values.signalsOrigins -}}
{{- join "," .Values.signalsOrigins -}}
{{- else -}}
{{- $proto := .Values.global.publicProtocol | default "https" -}}
{{- $out := list -}}
{{- range (.Values.global.publicHosts | default list) -}}
{{- if . -}}{{- $out = append $out (printf "%s://%s" $proto .) -}}{{- end -}}
{{- end -}}
{{- join "," (uniq $out) -}}
{{- end -}}
{{- end -}}

{{- define "keycloak.image" -}}
{{- $tag := default .Chart.AppVersion .Values.image.tag -}}
{{- if .Values.global.imageRegistry -}}
{{ .Values.global.imageRegistry }}/{{ .Values.image.repository }}:{{ $tag }}
{{- else -}}
{{ .Values.image.repository }}:{{ $tag }}
{{- end -}}
{{- end -}}

{{- /* Keycloak's OWN host — KC_HOSTNAME, the auth Ingresses, and the `iss` claim.
       Falls back to global.publicHost (the legacy shared-host arrangement).
       Changing it changes the issuer: move the apps in the same window. */ -}}
{{- define "keycloak.authHost" -}}
{{- $kc := .Values.global.keycloak | default dict -}}
{{- $h := $kc.host | default .Values.global.publicHost -}}
{{- required "keycloak: no host — set global.keycloak.host (preferred) or global.publicHost" $h -}}
{{- end -}}

{{- /* The AGGREGATOR APP's base URL, not Keycloak's (name is historical). Feeds
       __PUBLIC_BASE_URL__, whose every occurrence in realm.json is a client
       allow-list entry — never the issuer. Point it at the auth host and
       aggregator-portal's redirect URI breaks. Use keycloak.authHost instead. */ -}}
{{- define "keycloak.publicBaseUrl" -}}
{{ .Values.global.publicProtocol }}://{{ .Values.global.publicHost }}
{{- end -}}

{{- define "keycloak.imagePullSecrets" -}}
{{- with .Values.global.imagePullSecrets }}
imagePullSecrets:
{{- range . }}
  - name: {{ . }}
{{- end }}
{{- end }}
{{- end -}}

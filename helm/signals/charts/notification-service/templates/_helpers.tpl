{{/*
Expand the name of the chart.
*/}}
{{- define "dpg-notification-service.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fully qualified app name.
*/}}
{{- define "dpg-notification-service.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Chart label.
*/}}
{{- define "dpg-notification-service.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels.
*/}}
{{- define "dpg-notification-service.labels" -}}
helm.sh/chart: {{ include "dpg-notification-service.chart" . }}
{{ include "dpg-notification-service.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels.
*/}}
{{- define "dpg-notification-service.selectorLabels" -}}
app.kubernetes.io/name: {{ include "dpg-notification-service.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
ServiceAccount name.
*/}}
{{- define "dpg-notification-service.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "dpg-notification-service.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
envFrom Secret name.
*/}}
{{- define "dpg-notification-service.secretName" -}}
{{- if and (not .Values.secrets.create) .Values.secrets.existingSecret }}
{{- .Values.secrets.existingSecret }}
{{- else }}
{{- include "dpg-notification-service.fullname" . }}
{{- end }}
{{- end }}

{{/*
Internal-secrets-json Secret name (mounted file, not envFrom).
*/}}
{{- define "dpg-notification-service.internalSecretsName" -}}
{{- if and (not .Values.internalSecrets.create) .Values.internalSecrets.existingSecret }}
{{- .Values.internalSecrets.existingSecret }}
{{- else }}
{{- printf "%s-internal" (include "dpg-notification-service.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/*
Image pull secrets: the component's own value if set, else
global.imagePullSecrets. Emits nothing when both are empty.
*/}}
{{- define "dpg-notification-service.imagePullSecrets" -}}
{{- with (.Values.imagePullSecrets | default (.Values.global | default dict).imagePullSecrets) -}}
imagePullSecrets:
{{- toYaml . | nindent 2 }}
{{- end }}
{{- end -}}

{{/*
Keycloak bearer-auth env (NS_KEYCLOAK_ISSUER, NS_KEYCLOAK_JWKS_URI), DERIVED from
the shared Keycloak coordinates rather than set as free values, so the issuer
NS checks is byte-identical to the one the keycloak release mints and signals
validates. Same resolution chain as helm/signals/charts/api/templates/configmap.yaml,
most specific first:
  realm       keycloak.realm -> global.keycloak.realm -> global.keycloakRealm
  public base keycloak.publicBaseUrl -> global.keycloak.publicBaseUrl
              -> <publicProtocol>://global.keycloak.host/auth
              -> <publicProtocol>://global.publicHost/auth
  internal    keycloak.internalBaseUrl -> global.keycloak.internalBaseUrl
The host/publicHost fallbacks matter: environments leave publicBaseUrl empty and
rely on them, exactly as signals does.

Optional, unlike signals: if the realm or the public base does not resolve,
NEITHER variable is emitted. NS then runs with bearer auth off and keeps serving
HMAC callers. The JWKS URI uses the in-cluster address; without one it is
omitted and NS derives it from the issuer. Emits YAML map lines (or nothing).
*/}}
{{- define "dpg-notification-service.keycloakEnv" -}}
{{- $kc := .Values.keycloak | default dict }}
{{- $g := .Values.global | default dict }}
{{- $gkc := $g.keycloak | default dict }}
{{- $realm := $kc.realm | default $gkc.realm | default $g.keycloakRealm }}
{{- $publicBase := $kc.publicBaseUrl | default $gkc.publicBaseUrl }}
{{- if and (not $publicBase) $gkc.host }}
{{- $publicBase = printf "%s://%s/auth" ($g.publicProtocol | default "https") $gkc.host }}
{{- end }}
{{- if and (not $publicBase) $g.publicHost }}
{{- $publicBase = printf "%s://%s/auth" ($g.publicProtocol | default "https") $g.publicHost }}
{{- end }}
{{- $internalBase := $kc.internalBaseUrl | default $gkc.internalBaseUrl }}
{{- if and $realm $publicBase }}
NS_KEYCLOAK_ISSUER: {{ printf "%s/realms/%s" (trimSuffix "/" $publicBase) $realm | quote }}
{{- if $internalBase }}
NS_KEYCLOAK_JWKS_URI: {{ printf "%s/realms/%s/protocol/openid-connect/certs" (trimSuffix "/" $internalBase) $realm | quote }}
{{- end }}
{{- end }}
{{- end -}}

{{/*
  ───────────────────────────────────────────────────────────────────────────
  aggregator-dpg umbrella helpers
  Centralises naming, labels, image refs, and cross-cutting references that
  subcharts also need (via `include` with $top context).
  ───────────────────────────────────────────────────────────────────────────
*/}}

{{/*
  Full release-scoped name (release name truncated to 63 chars).
*/}}
{{- define "aggregator.fullname" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
  Service-qualified name: {release}-{component}.
*/}}
{{- define "aggregator.componentName" -}}
{{- $top := .top -}}
{{- $component := .component -}}
{{- printf "%s-%s" (include "aggregator.fullname" $top) $component | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
  Common labels applied to every resource in the chart.
*/}}
{{- define "aggregator.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: aggregator-dpg
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end -}}

{{/*
  Per-component selector labels. Usage:
    {{- include "aggregator.selectorLabels" (dict "top" $ "component" "api") | nindent 4 }}
*/}}
{{- define "aggregator.selectorLabels" -}}
{{- $top := .top -}}
app.kubernetes.io/name: aggregator-dpg
app.kubernetes.io/component: {{ .component }}
app.kubernetes.io/instance: {{ $top.Release.Name }}
{{- end -}}

{{/*
  Name of the Secret carrying credentials. If existingSecret is set we
  reference it; otherwise we use the umbrella-rendered Secret.
*/}}
{{- define "aggregator.secretName" -}}
{{- $existing := default .Values.secrets.existingSecret .Values.global.existingSecret -}}
{{- if $existing -}}
{{- $existing -}}
{{- else -}}
{{- printf "%s-secrets" (include "aggregator.fullname" .) -}}
{{- end -}}
{{- end -}}

{{/*
  Browser-facing base URL (e.g. https://portal.example.com).
*/}}
{{- define "aggregator.publicBaseUrl" -}}
{{ .Values.global.publicProtocol }}://{{ .Values.global.publicHost }}
{{- end -}}

{{/*
  OIDC issuer URL (matches what the browser sees).
*/}}
{{- define "aggregator.oidcIssuer" -}}
{{ include "aggregator.publicBaseUrl" . }}/auth/realms/{{ .Values.global.keycloakRealm }}
{{- end -}}

{{/*
  Public Keycloak base (e.g. https://portal.example.com/auth).
*/}}
{{- define "aggregator.keycloakUrl" -}}
{{ include "aggregator.publicBaseUrl" . }}/auth
{{- end -}}

{{/*
  Internal in-cluster Keycloak Service DNS (used by hooks + workers that
  don't need the public issuer string).
*/}}
{{- define "aggregator.keycloakInternalUrl" -}}
http://{{ include "aggregator.fullname" . }}-keycloak:{{ .Values.keycloak.service.port }}/auth
{{- end -}}

{{/*
  SMTP host. Must be set by the operator (mail.smtp.host) — no in-cluster
  mailcatcher ships with the chart. Empty value surfaces as an empty env
  var so callers can fail fast.
*/}}
{{- define "aggregator.smtpHost" -}}
{{- .Values.mail.smtp.host -}}
{{- end -}}

{{/*
  Postgres host. Prefers global.dataPlatform.postgresHost (full endpoint, e.g. an
  RDS hostname) when set; otherwise falls back to the in-cluster cross-namespace
  FQDN built from postgresService + namespace.
*/}}
{{- define "aggregator.postgresHost" -}}
{{- if .Values.global.dataPlatform.postgresHost -}}
{{- .Values.global.dataPlatform.postgresHost -}}
{{- else -}}
{{- printf "%s.%s.svc.cluster.local" .Values.global.dataPlatform.postgresService .Values.global.dataPlatform.namespace -}}
{{- end -}}
{{- end -}}

{{/*
  Redis host — shared instance in the common-services release.
*/}}
{{- define "aggregator.redisHost" -}}
{{- printf "%s.%s.svc.cluster.local" .Values.global.dataPlatform.redisService .Values.global.dataPlatform.namespace -}}
{{- end -}}

{{/*
  Postgres connection URL used by api + worker.
*/}}
{{- define "aggregator.databaseUrl" -}}
postgres://{{ .Values.postgresql.auth.username }}:$(POSTGRES_PASSWORD)@{{ include "aggregator.postgresHost" . }}:5432/{{ .Values.postgresql.auth.database }}
{{- end -}}

{{/*
  Image reference helper.
  Usage:
    {{- include "aggregator.image" (dict "top" $ "image" .Values.aggregator-api.image) }}
*/}}
{{- define "aggregator.image" -}}
{{- $top := .top -}}
{{- $img := .image -}}
{{- $tag := default $top.Chart.AppVersion $img.tag -}}
{{- if $top.Values.global.imageRegistry -}}
{{ $top.Values.global.imageRegistry }}/{{ $img.repository }}:{{ $tag }}
{{- else -}}
{{ $img.repository }}:{{ $tag }}
{{- end -}}
{{- end -}}

{{/*
  hostAliases block. Emit nothing when the list is empty so the Pod spec
  stays clean. Caller decides indentation:
    {{- include "aggregator.hostAliases" $ | nindent 6 }}
*/}}
{{- define "aggregator.hostAliases" -}}
{{- with .Values.global.hostAliases }}
hostAliases:
{{- range . }}
  - ip: {{ .ip | quote }}
    hostnames:
{{- range .hostnames }}
      - {{ . | quote }}
{{- end }}
{{- end }}
{{- end }}
{{- end -}}

{{/*
  Validate a mandatory secret: fail the render (loudly) when the value is empty
  or still a `change-me` placeholder, otherwise return it. This is what turns a
  forgotten credential into a deploy-time error instead of a cluster running on
  a well-known default. Only invoked when NOT using global.existingSecret.
  Usage:
    {{ include "aggregator.requireSecret" (dict "value" .Values.secrets.sessionKey "name" "sessionKey") | quote }}
*/}}
{{- define "aggregator.requireSecret" -}}
{{- $value := .value -}}
{{- $name := .name -}}
{{- if or (not $value) (hasPrefix "change-me" (toString $value)) -}}
{{- fail (printf "secrets.%s must be set to a real value (found empty or a 'change-me' placeholder). Provide it via the generated global-credentials.yaml / -f overlay, or set global.existingSecret to a pre-created Secret." $name) -}}
{{- end -}}
{{- $value -}}
{{- end -}}

{{/*
  imagePullSecrets block.
*/}}
{{- define "aggregator.imagePullSecrets" -}}
{{- with .Values.global.imagePullSecrets }}
imagePullSecrets:
{{- range . }}
  - name: {{ . }}
{{- end }}
{{- end }}
{{- end -}}

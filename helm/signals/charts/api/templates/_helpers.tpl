{{/*
Expand the name of the chart.
*/}}
{{- define "dpg-api.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fully qualified app name.
*/}}
{{- define "dpg-api.fullname" -}}
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
{{- define "dpg-api.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels.
*/}}
{{- define "dpg-api.labels" -}}
helm.sh/chart: {{ include "dpg-api.chart" . }}
{{ include "dpg-api.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels.
*/}}
{{- define "dpg-api.selectorLabels" -}}
app.kubernetes.io/name: {{ include "dpg-api.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
ServiceAccount name.
*/}}
{{- define "dpg-api.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "dpg-api.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Secret name to mount as envFrom.
*/}}
{{- define "dpg-api.secretName" -}}
{{- if and (not .Values.secrets.create) .Values.secrets.existingSecret }}
{{- .Values.secrets.existingSecret }}
{{- else }}
{{- include "dpg-api.fullname" . }}
{{- end }}
{{- end }}

{{/*
envFrom sources for the migrate Job. The Job runs as a pre-install/pre-upgrade
hook, so it must NOT reference the api's own ConfigMap/Secret — those are
ordinary release resources that Helm creates only after pre-install hooks have
finished, so the Job would fail with CreateContainerConfigError. Point it at the
hook-scoped copies from migrate-env.yaml instead. An operator-supplied
existingSecret already exists outside the release, so that one is consumed
directly.
*/}}
{{- define "dpg-api.migrateEnvFrom" -}}
- configMapRef:
    name: {{ include "dpg-api.fullname" . }}-migrate-env
{{- if .Values.secrets.create }}
- secretRef:
    name: {{ include "dpg-api.fullname" . }}-migrate-env
{{- else }}
- secretRef:
    name: {{ include "dpg-api.secretName" . }}
{{- end }}
{{- end }}

{{/*
Image pull secrets: the component's own value if set, else
global.imagePullSecrets. Emits nothing when both are empty.
*/}}
{{- define "dpg-api.imagePullSecrets" -}}
{{- with (.Values.imagePullSecrets | default (.Values.global | default dict).imagePullSecrets) -}}
imagePullSecrets:
{{- toYaml . | nindent 2 }}
{{- end }}
{{- end -}}

{{/*
Pod-level /etc/hosts entries, from `global.hostAliases`. Same shape and the same
global key the aggregator web/api subcharts already use.

WHY THIS EXISTS: a cluster whose firewall forbids hairpin NAT cannot reach its
own public hostnames from inside. Server-side calls to Keycloak (OIDC discovery,
JWKS, admin REST) then hang until they time out, while browser logins work fine
because the browser is outside. Mapping the public hostname to the in-cluster
ingress IP keeps the URL — and therefore the OIDC issuer, which tokens are
validated against — unchanged.

Renders nothing when the list is empty, so AWS is byte-identical.
*/}}
{{- define "dpg-api.hostAliases" -}}
{{- with (.Values.global).hostAliases }}
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

{{/* Release-scoped name, truncated to 63 chars. */}}
{{- define "campaign-manager.fullname" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Common labels. */}}
{{- define "campaign-manager.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: campaign-manager
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end -}}

{{/* Selector labels. */}}
{{- define "campaign-manager.selectorLabels" -}}
app.kubernetes.io/name: campaign-manager
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/* Image reference: repository:tag, tag defaults to Chart.appVersion. */}}
{{- define "campaign-manager.image" -}}
{{ .Values.image.repository }}:{{ default .Chart.AppVersion .Values.image.tag }}
{{- end -}}

{{/* Name of the Secret holding credentials (existing or chart-rendered). */}}
{{- define "campaign-manager.secretName" -}}
{{- if .Values.secrets.existingSecret -}}
{{- .Values.secrets.existingSecret -}}
{{- else -}}
{{- printf "%s-secrets" (include "campaign-manager.fullname" .) -}}
{{- end -}}
{{- end -}}

{{/* imagePullSecrets block. */}}
{{- define "campaign-manager.imagePullSecrets" -}}
{{- with .Values.global.imagePullSecrets }}
imagePullSecrets:
{{- range . }}
  - name: {{ . }}
{{- end }}
{{- end }}
{{- end -}}

{{/* Pipeline: resource names and labels. */}}
{{- define "campaign-manager.pipeline.name" -}}
{{- printf "%s-pipeline" (include "campaign-manager.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "campaign-manager.pipeline.labels" -}}
{{ include "campaign-manager.labels" . }}
app.kubernetes.io/component: pipeline
{{- end -}}

{{- define "campaign-manager.pipeline.selectorLabels" -}}
app.kubernetes.io/name: campaign-manager-pipeline
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "campaign-manager.pipeline.image" -}}
{{ .Values.pipeline.image.repository }}:{{ required "pipeline.image.tag is required when pipeline.enabled" .Values.pipeline.image.tag }}
{{- end -}}

{{/* Name of the Secret carrying DATABASE_URL, RAYA_API_KEY, CLIENT_SECRET. */}}
{{- define "campaign-manager.pipeline.secretName" -}}
{{- if .Values.pipeline.secrets.existingSecret -}}
{{- .Values.pipeline.secrets.existingSecret -}}
{{- else -}}
{{- printf "%s-secrets" (include "campaign-manager.pipeline.name" .) -}}
{{- end -}}
{{- end -}}

{{/* postgresql:// URL with the user and password percent-encoded. */}}
{{- define "campaign-manager.pipeline.databaseUrl" -}}
{{- $db := .Values.pipeline.database -}}
{{- printf "postgresql://%s:%s@%s:%v/%s" (urlquery (required "pipeline.database.user is required" $db.user) | replace "+" "%20") (urlquery (required "pipeline.database.password is required" $db.password) | replace "+" "%20") (required "pipeline.database.host is required" $db.host) $db.port (required "pipeline.database.name is required" $db.name) -}}
{{- end -}}

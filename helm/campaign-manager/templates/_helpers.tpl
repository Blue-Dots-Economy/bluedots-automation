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

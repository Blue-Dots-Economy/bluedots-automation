{{- define "app.fullname" -}}
{{- printf "%s-app" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "app.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: campaign-manager
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end -}}

{{- define "app.selectorLabels" -}}
app.kubernetes.io/name: campaign-manager-app
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "app.image" -}}
{{ .Values.image.repository }}:{{ required "app.image.tag is required" .Values.image.tag }}
{{- end -}}

{{- define "app.secretName" -}}
{{- if .Values.secrets.existingSecret -}}
{{- .Values.secrets.existingSecret -}}
{{- else -}}
{{- printf "%s-secrets" (include "app.fullname" .) -}}
{{- end -}}
{{- end -}}

{{/* Subchart-local, not shared — app/raya-sync/platform-sync pull independent images. */}}
{{- define "app.imagePullSecrets" -}}
{{- if .Values.imagePullSecret.private }}
imagePullSecrets:
  - name: {{ .Values.imagePullSecret.name }}
{{- end }}
{{- end -}}

{{- define "app.secretEnv" -}}
- name: {{ .name }}
  valueFrom:
    secretKeyRef:
      name: {{ include "app.secretName" .ctx }}
      key: {{ .name }}
      {{- if .optional }}
      optional: true
      {{- end }}
{{- end -}}

{{/* Duplicated across the three subcharts — keep in step. */}}
{{- define "app.databaseUrl" -}}
{{- printf "postgresql://%s:%s@%s:%v/%s" (urlquery (required "global.database.user is required" .user) | replace "+" "%20") (urlquery (required "global.database.password is required" .password) | replace "+" "%20") (required "global.database.host is required" .host) .port (required "global.database.name is required" .name) -}}
{{- end -}}

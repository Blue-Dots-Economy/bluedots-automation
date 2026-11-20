{{- define "platformSync.fullname" -}}
{{- printf "%s-platform-sync" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "platformSync.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: campaign-manager
app.kubernetes.io/component: platform-sync
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end -}}

{{- define "platformSync.selectorLabels" -}}
app.kubernetes.io/name: campaign-manager-platform-sync
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "platformSync.image" -}}
{{ .Values.image.repository }}:{{ required "platform-sync.image.tag is required when platform-sync.enabled" .Values.image.tag }}
{{- end -}}

{{- define "platformSync.secretName" -}}
{{- printf "%s-secrets" (include "platformSync.fullname" .) -}}
{{- end -}}

{{/* Subchart-local, not shared — app/raya-sync/platform-sync pull independent images. */}}
{{- define "platformSync.imagePullSecrets" -}}
{{- if .Values.imagePullSecret.private }}
imagePullSecrets:
  - name: {{ .Values.imagePullSecret.name }}
{{- end }}
{{- end -}}

{{- define "platformSync.secretEnv" -}}
- name: {{ .name }}
  valueFrom:
    secretKeyRef:
      name: {{ include "platformSync.secretName" .ctx }}
      key: {{ .name }}
      {{- if .optional }}
      optional: true
      {{- end }}
{{- end -}}

{{/* Duplicated across the three subcharts — keep in step. */}}
{{- define "platformSync.databaseUrl" -}}
{{- printf "postgresql://%s:%s@%s:%v/%s" (urlquery (required "global.database.user is required" .user) | replace "+" "%20") (urlquery (required "global.database.password is required" .password) | replace "+" "%20") (required "global.database.host is required" .host) .port (required "global.database.name is required" .name) -}}
{{- end -}}

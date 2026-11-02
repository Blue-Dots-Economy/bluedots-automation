{{- define "rayaSync.fullname" -}}
{{- printf "%s-raya-sync" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "rayaSync.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: campaign-manager
app.kubernetes.io/component: raya-sync
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end -}}

{{- define "rayaSync.selectorLabels" -}}
app.kubernetes.io/name: campaign-manager-raya-sync
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "rayaSync.image" -}}
{{ .Values.image.repository }}:{{ required "raya-sync.image.tag is required when raya-sync.enabled" .Values.image.tag }}
{{- end -}}

{{- define "rayaSync.secretName" -}}
{{- printf "%s-secrets" (include "rayaSync.fullname" .) -}}
{{- end -}}

{{/* Subchart-local, not shared — app/raya-sync/platform-sync pull independent images. */}}
{{- define "rayaSync.imagePullSecrets" -}}
{{- if .Values.imagePullSecret.private }}
imagePullSecrets:
  - name: {{ .Values.imagePullSecret.name }}
{{- end }}
{{- end -}}

{{- define "rayaSync.secretEnv" -}}
- name: {{ .name }}
  valueFrom:
    secretKeyRef:
      name: {{ include "rayaSync.secretName" .ctx }}
      key: {{ .name }}
      {{- if .optional }}
      optional: true
      {{- end }}
{{- end -}}

{{/* Duplicated across the three subcharts — keep in step. */}}
{{- define "rayaSync.databaseUrl" -}}
{{- printf "postgresql://%s:%s@%s:%v/%s" (urlquery (required "global.database.user is required" .user) | replace "+" "%20") (urlquery (required "global.database.password is required" .password) | replace "+" "%20") (required "global.database.host is required" .host) .port (required "global.database.name is required" .name) -}}
{{- end -}}

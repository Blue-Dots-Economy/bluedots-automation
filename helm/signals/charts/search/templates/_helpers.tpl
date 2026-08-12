{{- define "search.name" -}}search{{- end -}}
{{- define "search.fullname" -}}{{ .Release.Name }}-search{{- end -}}
{{- define "search.labels" -}}
app.kubernetes.io/name: {{ include "search.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}
{{- define "search.selectorLabels" -}}
app.kubernetes.io/name: {{ include "search.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
{{- define "search.serviceAccountName" -}}{{ include "search.fullname" . }}{{- end -}}
{{- define "search.secretName" -}}{{ .Values.secrets.existingSecret | default (printf "%s-secrets" (include "search.fullname" .)) }}{{- end -}}
{{/* Reuse the api subchart's network-schema ConfigMap (single source of network
configs; no duplication). Defaults to the api fullname pattern; override via
.Values.networkSchemasConfigMap if the api is named differently. */}}
{{- define "search.schemasConfigMapName" -}}{{ .Values.networkSchemasConfigMap | default (printf "%s-api-schemas" .Release.Name) }}{{- end -}}

{{- define "search-embeddings.name" -}}search-embeddings{{- end -}}
{{- define "search-embeddings.fullname" -}}{{ .Release.Name }}-search-embeddings{{- end -}}
{{- define "search-embeddings.labels" -}}
app.kubernetes.io/name: {{ include "search-embeddings.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}
{{- define "search-embeddings.selectorLabels" -}}
app.kubernetes.io/name: {{ include "search-embeddings.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
{{- define "search-embeddings.serviceAccountName" -}}{{ include "search-embeddings.fullname" . }}{{- end -}}

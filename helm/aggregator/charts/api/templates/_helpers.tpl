{{- define "api.fullname" -}}
{{- printf "%s-api" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "api.releaseFullname" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "api.secretName" -}}
{{- $existing := default "" .Values.global.existingSecret -}}
{{- if $existing -}}
{{- $existing -}}
{{- else -}}
{{- printf "%s-secrets" (include "api.releaseFullname" .) -}}
{{- end -}}
{{- end -}}

{{- define "api.globalConfigMap" -}}
{{- printf "%s-global" (include "api.releaseFullname" .) -}}
{{- end -}}

{{- define "api.appConfigMap" -}}
{{- printf "%s-api" (include "api.releaseFullname" .) -}}
{{- end -}}

{{- define "api.serviceName" -}}
{{- include "api.fullname" . -}}
{{- end -}}

{{- define "api.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- include "api.fullname" . -}}
{{- else -}}
default
{{- end -}}
{{- end -}}

{{- define "api.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: aggregator-dpg
app.kubernetes.io/name: aggregator-dpg
app.kubernetes.io/component: api
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end -}}

{{- define "api.selectorLabels" -}}
app.kubernetes.io/name: aggregator-dpg
app.kubernetes.io/component: api
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "api.image" -}}
{{- $tag := default .Chart.AppVersion .Values.image.tag -}}
{{- if .Values.global.imageRegistry -}}
{{ .Values.global.imageRegistry }}/{{ .Values.image.repository }}:{{ $tag }}
{{- else -}}
{{ .Values.image.repository }}:{{ $tag }}
{{- end -}}
{{- end -}}

{{- define "api.publicBaseUrl" -}}
{{ .Values.global.publicProtocol }}://{{ .Values.global.publicHost }}
{{- end -}}

{{- define "api.hostAliases" -}}
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

{{- define "api.imagePullSecrets" -}}
{{- with .Values.global.imagePullSecrets }}
imagePullSecrets:
{{- range . }}
  - name: {{ . }}
{{- end }}
{{- end }}
{{- end -}}

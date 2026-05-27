{{- define "worker.fullname" -}}
{{- printf "%s-worker" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "worker.releaseFullname" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "worker.secretName" -}}
{{- $existing := default "" .Values.global.existingSecret -}}
{{- if $existing -}}
{{- $existing -}}
{{- else -}}
{{- printf "%s-secrets" (include "worker.releaseFullname" .) -}}
{{- end -}}
{{- end -}}

{{- define "worker.globalConfigMap" -}}
{{- printf "%s-global" (include "worker.releaseFullname" .) -}}
{{- end -}}

{{- define "worker.appConfigMap" -}}
{{- printf "%s-worker" (include "worker.releaseFullname" .) -}}
{{- end -}}

{{- define "worker.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- include "worker.fullname" . -}}
{{- else -}}
default
{{- end -}}
{{- end -}}

{{- define "worker.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: aggregator-dpg
app.kubernetes.io/name: aggregator-dpg
app.kubernetes.io/component: worker
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end -}}

{{- define "worker.selectorLabels" -}}
app.kubernetes.io/name: aggregator-dpg
app.kubernetes.io/component: worker
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "worker.image" -}}
{{- $tag := default .Chart.AppVersion .Values.image.tag -}}
{{- if .Values.global.imageRegistry -}}
{{ .Values.global.imageRegistry }}/{{ .Values.image.repository }}:{{ $tag }}
{{- else -}}
{{ .Values.image.repository }}:{{ $tag }}
{{- end -}}
{{- end -}}

{{- define "worker.imagePullSecrets" -}}
{{- with .Values.global.imagePullSecrets }}
imagePullSecrets:
{{- range . }}
  - name: {{ . }}
{{- end }}
{{- end }}
{{- end -}}

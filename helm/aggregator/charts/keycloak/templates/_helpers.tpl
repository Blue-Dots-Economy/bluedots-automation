{{- define "keycloak.fullname" -}}
{{- printf "%s-keycloak" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "keycloak.releaseFullname" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "keycloak.secretName" -}}
{{- $existing := default "" .Values.global.existingSecret -}}
{{- if $existing -}}
{{- $existing -}}
{{- else -}}
{{- printf "%s-secrets" (include "keycloak.releaseFullname" .) -}}
{{- end -}}
{{- end -}}

{{- define "keycloak.globalConfigMap" -}}
{{- printf "%s-global" (include "keycloak.releaseFullname" .) -}}
{{- end -}}

{{- define "keycloak.envConfigMap" -}}
{{- printf "%s-keycloak" (include "keycloak.releaseFullname" .) -}}
{{- end -}}

{{- define "keycloak.realmConfigMap" -}}
{{- printf "%s-keycloak-realm" (include "keycloak.releaseFullname" .) -}}
{{- end -}}

{{- define "keycloak.renderScriptConfigMap" -}}
{{- printf "%s-keycloak-render" (include "keycloak.releaseFullname" .) -}}
{{- end -}}

{{- define "keycloak.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: aggregator-dpg
app.kubernetes.io/name: aggregator-dpg
app.kubernetes.io/component: keycloak
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end -}}

{{- define "keycloak.selectorLabels" -}}
app.kubernetes.io/name: aggregator-dpg
app.kubernetes.io/component: keycloak
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "keycloak.image" -}}
{{- $tag := default .Chart.AppVersion .Values.image.tag -}}
{{- if .Values.global.imageRegistry -}}
{{ .Values.global.imageRegistry }}/{{ .Values.image.repository }}:{{ $tag }}
{{- else -}}
{{ .Values.image.repository }}:{{ $tag }}
{{- end -}}
{{- end -}}

{{- define "keycloak.publicBaseUrl" -}}
{{ .Values.global.publicProtocol }}://{{ .Values.global.publicHost }}
{{- end -}}

{{- define "keycloak.imagePullSecrets" -}}
{{- with .Values.global.imagePullSecrets }}
imagePullSecrets:
{{- range . }}
  - name: {{ . }}
{{- end }}
{{- end }}
{{- end -}}

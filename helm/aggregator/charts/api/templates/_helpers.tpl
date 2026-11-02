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

{{- /*
Labels for the on-demand instance-upgrade Job. Same as api.labels but with a
distinct component, so the Job's pod is never selected by the api Service
(which selects component=api). Keep these two helpers' non-component labels in
step with api.labels / api.selectorLabels.
*/ -}}
{{- define "api.jobSelectorLabels" -}}
app.kubernetes.io/name: aggregator-dpg
app.kubernetes.io/component: instance-upgrade
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "api.jobLabels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: aggregator-dpg
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{ include "api.jobSelectorLabels" . }}
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

{{/* The two config-map sources, shared by the Deployment and the instance-upgrade Job. */}}
{{- define "api.envFrom" -}}
envFrom:
  - configMapRef:
      name: {{ include "api.globalConfigMap" . }}
  - configMapRef:
      name: {{ include "api.appConfigMap" . }}
{{- end -}}

{{/* The container env, shared by the Deployment and the instance-upgrade Job. */}}
{{- define "api.env" -}}
env:
  - name: POSTGRES_PASSWORD
    valueFrom:
      secretKeyRef:
        name: {{ include "api.secretName" . }}
        key: POSTGRES_PASSWORD
  # POSTGRES_USER + POSTGRES_DB + POSTGRES_HOST come from the
  # umbrella's `{release}-global` ConfigMap (envFrom above).
  - name: DATABASE_URL
    value: "postgres://$(POSTGRES_USER):$(POSTGRES_PASSWORD)@$(POSTGRES_HOST):5432/$(POSTGRES_DB)"
  # REDIS_HOST + REDIS_PORT come from the umbrella's `{release}-global`
  # ConfigMap (envFrom above); REDIS_PASSWORD from the umbrella Secret.
  - name: REDIS_PASSWORD
    valueFrom:
      secretKeyRef:
        name: {{ include "api.secretName" . }}
        key: REDIS_PASSWORD
  - name: REDIS_URL
    value: "redis://:$(REDIS_PASSWORD)@$(REDIS_HOST):$(REDIS_PORT)"
  - name: KEYCLOAK_ADMIN_CLIENT_SECRET
    valueFrom:
      secretKeyRef:
        name: {{ include "api.secretName" . }}
        key: KEYCLOAK_ADMIN_CLIENT_SECRET
  - name: APPROVAL_TOKEN_SECRET
    valueFrom:
      secretKeyRef:
        name: {{ include "api.secretName" . }}
        key: APPROVAL_TOKEN_SECRET
  - name: SMTP_USER
    valueFrom:
      secretKeyRef:
        name: {{ include "api.secretName" . }}
        key: SMTP_USER
        optional: true
  - name: SMTP_PASSWORD
    valueFrom:
      secretKeyRef:
        name: {{ include "api.secretName" . }}
        key: SMTP_PASSWORD
        optional: true
  - name: AWS_ACCESS_KEY_ID
    valueFrom:
      secretKeyRef:
        name: {{ include "api.secretName" . }}
        key: AWS_ACCESS_KEY_ID
        optional: true
  - name: AWS_SECRET_ACCESS_KEY
    valueFrom:
      secretKeyRef:
        name: {{ include "api.secretName" . }}
        key: AWS_SECRET_ACCESS_KEY
        optional: true
  - name: SIGNALSTACK_ADMIN_KEY
    valueFrom:
      secretKeyRef:
        name: {{ include "api.secretName" . }}
        key: SIGNALSTACK_ADMIN_KEY
        optional: true
{{- end -}}

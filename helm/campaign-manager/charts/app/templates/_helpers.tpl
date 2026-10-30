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

{{/*
Keycloak login settings as a YAML map, for the ConfigMap and the migrate Job.
global.keycloak is only set by install.sh deploys; a standalone install sets
app.keycloak.baseUrl itself.
*/}}
{{- define "app.loginEnv" -}}
{{- $g := .Values.global -}}
{{- $kc := $g.keycloak | default dict -}}
{{- $host := default $g.publicHost .Values.ingress.host -}}
{{- $kcBase := $kc.publicBaseUrl | default "" -}}
{{- if and $g.keycloak (not $kcBase) -}}
{{- $kcBase = printf "%s://%s/auth" $g.publicProtocol (default $g.publicHost $kc.host) -}}
{{- end -}}
APP_BASE_URL: {{ required "app.appBaseUrl is required (or set app.ingress.host)" (default (and $host (printf "%s://%s" $g.publicProtocol $host)) .Values.appBaseUrl) | quote }}
KEYCLOAK_BASE_URL: {{ required "app.keycloak.baseUrl is required" (default $kcBase .Values.keycloak.baseUrl) | quote }}
{{- with default $kc.internalBaseUrl .Values.keycloak.internalBaseUrl }}
KEYCLOAK_INTERNAL_BASE_URL: {{ . | quote }}
{{- end }}
KEYCLOAK_REALM: {{ required "app.keycloak.realm is required (or global.keycloakRealm)" (default $g.keycloakRealm .Values.keycloak.realm) | quote }}
KEYCLOAK_CLIENT_ID: {{ required "app.keycloak.clientId is required" .Values.keycloak.clientId | quote }}
{{- with .Values.bootstrapAdminEmail }}
BOOTSTRAP_ADMIN_EMAIL: {{ . | quote }}
{{- end }}
{{- end -}}

{{/* Duplicated across the three subcharts — keep in step. */}}
{{- define "app.databaseUrl" -}}
{{- printf "postgresql://%s:%s@%s:%v/%s" (urlquery (required "global.database.user is required" .user) | replace "+" "%20") (urlquery (required "global.database.password is required" .password) | replace "+" "%20") (required "global.database.host is required" .host) .port (required "global.database.name is required" .name) -}}
{{- end -}}

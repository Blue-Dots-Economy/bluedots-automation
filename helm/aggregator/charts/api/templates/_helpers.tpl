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

{{/*
  The api's RBAC_MODE: off | log | enforce; anything else fails the render.
  An unquoted `off` is read by YAML as false, so false means off.
*/}}
{{- define "api.rbacMode" -}}
{{- $mode := toString .Values.rbac.mode -}}
{{- if eq $mode "false" -}}{{- $mode = "off" -}}{{- end -}}
{{- if not (has $mode (list "off" "log" "enforce")) -}}
{{- fail (printf "aggregator-api.rbac.mode must be off, log or enforce (got %q)" $mode) -}}
{{- end -}}
{{- $mode -}}
{{- end -}}

{{/* "true" when the pod runs the RBAC edge (Envoy + OPA sidecars): mode log or enforce. */}}
{{- define "api.rbacEdge" -}}
{{- if ne (include "api.rbacMode" .) "off" -}}true{{- end -}}
{{- end -}}

{{/*
  The api's health check for its probes. Without the edge the kubelet calls
  /health/ready on the `http` port. With the edge the api binds 127.0.0.1,
  which an httpGet probe cannot reach, and probing through Envoy would restart
  the api whenever OPA is down; so node, the image's only interpreter, calls it
  on loopback.
*/}}
{{- define "api.readyCheck" -}}
{{- if include "api.rbacEdge" . -}}
exec:
  command:
    - node
    - -e
    - "fetch('http://127.0.0.1:{{ .Values.service.port }}/health/ready').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"
{{- else -}}
httpGet:
  path: /health/ready
  port: http
{{- end -}}
{{- end -}}

{{/* OPA image, by digest when one is set. */}}
{{- define "api.opaImage" -}}
{{- $img := .Values.rbac.opa.image -}}
{{- if $img.digest -}}
{{ $img.repository }}:{{ $img.tag }}@{{ $img.digest }}
{{- else -}}
{{ $img.repository }}:{{ $img.tag }}
{{- end -}}
{{- end -}}

{{/* Envoy (RBAC edge) image, by digest when one is set. */}}
{{- define "api.envoyImage" -}}
{{- $img := .Values.rbac.envoy.image -}}
{{- if $img.digest -}}
{{ $img.repository }}:{{ $img.tag }}@{{ $img.digest }}
{{- else -}}
{{ $img.repository }}:{{ $img.tag }}
{{- end -}}
{{- end -}}

{{/*
  Values the edge-init container fills into the Envoy template (aggregator-dpg
  infra/envoy/envoy.yaml), as container env entries. Everything in the pod is
  on 127.0.0.1. The issuer is the PUBLIC one the api checks tokens against
  (aggregator.oidcIssuer, the same base as KEYCLOAK_URL); the signing keys are
  fetched from Keycloak inside the cluster (aggregator.keycloakInternalUrl).
*/}}
{{- define "api.edgeTemplateEnv" -}}
{{- $kc := urlParse (include "aggregator.keycloakInternalUrl" .) -}}
{{- $kcHost := regexReplaceAll ":[0-9]+$" $kc.host "" -}}
{{- $kcPort := regexFind "[0-9]+$" (regexFind ":[0-9]+$" $kc.host) | default (ternary "443" "80" (eq $kc.scheme "https")) -}}
- name: ADMIN_ADDRESS
  value: "127.0.0.1"
- name: LISTEN_PORT
  value: {{ .Values.rbac.envoy.port | quote }}
- name: API_HOST
  value: "127.0.0.1"
- name: API_PORT
  value: {{ .Values.service.port | quote }}
- name: OPA_HOST
  value: "127.0.0.1"
- name: KEYCLOAK_HOST
  value: {{ $kcHost | quote }}
- name: KEYCLOAK_PORT
  value: {{ $kcPort | quote }}
- name: JWT_ISSUER
  value: {{ include "aggregator.oidcIssuer" . | quote }}
- name: JWKS_URI
  value: {{ printf "%s/realms/%s/protocol/openid-connect/certs" (include "aggregator.keycloakInternalUrl" .) .Values.global.keycloakRealm | quote }}
{{- end -}}

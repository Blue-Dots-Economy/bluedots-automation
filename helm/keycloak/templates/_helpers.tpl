{{- /*
Helpers for the keycloak-platform umbrella. The keycloak subchart keeps its own
`keycloak.*` helpers; these are for the release-level Secret, init Job and NOTES.
*/ -}}

{{- define "keycloak-platform.fullname" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "keycloak-platform.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: common-services
app.kubernetes.io/name: keycloak
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end -}}

{{- /*
Secret name. `global.existingSecret` bypasses the rendered Secret entirely —
the operator must pre-create it carrying every key listed in templates/secrets.yaml.
Also how `helm lint`/`helm template` skip the requireSecret guard.
*/ -}}
{{- define "keycloak-platform.secretName" -}}
{{- $existing := default "" .Values.global.existingSecret -}}
{{- if $existing -}}
{{- $existing -}}
{{- else -}}
{{- printf "%s-secrets" (include "keycloak-platform.fullname" .) -}}
{{- end -}}
{{- end -}}

{{- /*
The realm name. Single source for the whole platform: the subchart's KC config,
the init Job, the Kong login rate-limit path, and both DPGs' KEYCLOAK_REALM.
No literal default anywhere — a per-instance value must be supplied.
*/ -}}
{{- define "keycloak-platform.realm" -}}
{{- required "global.keycloakRealm is required — the realm name is per-instance and must not default to a literal" .Values.global.keycloakRealm -}}
{{- end -}}

{{- define "keycloak-platform.publicBaseUrl" -}}
{{ .Values.global.publicProtocol }}://{{ .Values.global.publicHost }}
{{- end -}}

{{- /*
In-cluster base URL for server-to-server callers (the init Job, and what the
DPGs use for JWKS/Admin REST when they should not egress via Kong).
Derived from the release + namespace so it follows a rename.
*/ -}}
{{- define "keycloak-platform.internalUrl" -}}
{{- $svc := printf "%s-keycloak" (include "keycloak-platform.fullname" .) -}}
{{- printf "http://%s.%s.svc.cluster.local:%v/auth" $svc .Release.Namespace (.Values.keycloak.service.port | default 8080) -}}
{{- end -}}

{{- define "keycloak-platform.imagePullSecrets" -}}
{{- with .Values.global.imagePullSecrets }}
imagePullSecrets:
{{- range . }}
  - name: {{ . }}
{{- end }}
{{- end }}
{{- end -}}

{{- /*
Fail the render on a missing or placeholder secret, so the platform can never
deploy identity on a well-known default. Mirrors aggregator.requireSecret.
*/ -}}
{{- define "keycloak-platform.requireSecret" -}}
{{- $v := .value | default "" -}}
{{- if or (eq $v "") (eq $v "change-me") (hasPrefix "change-me" $v) -}}
{{- fail (printf "secrets.%s must be set to a real value (got %q). Real deploys supply it from the generated global-secrets.yaml; static renders should pass --set global.existingSecret=<name> to skip the Secret block." .name $v) -}}
{{- else -}}
{{- $v -}}
{{- end -}}
{{- end -}}

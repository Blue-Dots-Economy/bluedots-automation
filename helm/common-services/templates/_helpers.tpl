{{/*
Common labels for platform-managed resources.
*/}}
{{- define "platform.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{/*
Image pull secrets for this chart's OWN pod-producing templates (the vendored
subcharts each have their own equivalent).

WHY THIS EXISTS: these four templates previously emitted no imagePullSecrets at
all, so on a private registry their pods pulled anonymously and failed with
  pull access denied ... authorization failed: no basic auth credentials
The only workaround was patching the namespace's `default` ServiceAccount by
hand — invisible in the repo, and silently lost whenever the namespace is
recreated. This removes the need for that.

FORMAT: `global.imagePullSecrets` is a list of STRINGS here, matching this
chart's subcharts (minio, redis). Do not switch it to the {name: x} map form —
signals uses maps, these do not, and the two cannot share one value. See the
comment on `global:` in values.yaml.
*/}}
{{- define "platform.imagePullSecrets" -}}
{{- with (.Values.global).imagePullSecrets }}
imagePullSecrets:
{{- range . }}
  - name: {{ . }}
{{- end }}
{{- end }}
{{- end -}}

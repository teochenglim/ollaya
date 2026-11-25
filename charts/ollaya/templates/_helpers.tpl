{{- define "ollaya.fullname" -}}
{{- if contains .Chart.Name .Release.Name -}}{{ .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else -}}{{ printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" }}{{- end -}}
{{- end -}}

{{- define "ollaya.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{- define "ollaya.selector" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "ollaya.image" -}}
{{- $tag := .Values.image.tag | default .Chart.AppVersion -}}
{{- if .Values.gpu.enabled -}}{{ printf "%s:%s-%s" .Values.image.repository $tag .Values.gpu.variant }}
{{- else -}}{{ printf "%s:%s" .Values.image.repository $tag }}{{- end -}}
{{- end -}}

{{- define "ollaya.apiSecretName" -}}
{{- if .Values.apiKey.existingSecret -}}{{ .Values.apiKey.existingSecret }}
{{- else if or .Values.apiKey.value .Values.apiKey.generate -}}{{ include "ollaya.fullname" . }}-api{{- end -}}
{{- end -}}

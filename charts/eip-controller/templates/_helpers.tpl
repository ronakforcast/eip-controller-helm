{{- define "eip-controller.name" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "eip-controller.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
app.kubernetes.io/name: eip-controller
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "eip-controller.selectorLabels" -}}
app.kubernetes.io/name: eip-controller
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "eip-controller.serviceAccountName" -}}
{{- if .Values.serviceAccount.name }}
{{- .Values.serviceAccount.name }}
{{- else }}
{{- include "eip-controller.name" . }}
{{- end }}
{{- end }}

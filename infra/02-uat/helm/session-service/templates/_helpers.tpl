{{- define "session-service.labels" -}}
app.kubernetes.io/name: session-service
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

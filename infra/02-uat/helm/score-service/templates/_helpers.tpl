{{- define "score-service.labels" -}}
app.kubernetes.io/name: score-service
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

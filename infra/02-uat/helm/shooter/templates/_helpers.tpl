{{- define "shooter.labels" -}}
app.kubernetes.io/name: shooter
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

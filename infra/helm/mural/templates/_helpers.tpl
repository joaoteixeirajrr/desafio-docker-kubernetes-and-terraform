{{/*
Helpers de nomes e labels do chart Mural.
*/}}

{{- define "mural.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "mural.fullname" -}}
{{- printf "%s" (include "mural.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Labels comuns a todos os recursos. */}}
{{- define "mural.labels" -}}
app.kubernetes.io/name: {{ include "mural.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{/* Nome do Service do Postgres (headless), usado na DATABASE_URL. */}}
{{- define "mural.postgres.service" -}}
{{- printf "%s-postgres" (include "mural.fullname" .) -}}
{{- end -}}

{{/* Nome do Service da API, usado pelo nginx como upstream. */}}
{{- define "mural.api.service" -}}
{{- printf "%s-api" (include "mural.fullname" .) -}}
{{- end -}}

{{/* Nome do Service do front. */}}
{{- define "mural.web.service" -}}
{{- printf "%s-web" (include "mural.fullname" .) -}}
{{- end -}}

{{/* Nome do Secret com a credencial do banco. */}}
{{- define "mural.secret.name" -}}
{{- printf "%s-db" (include "mural.fullname" .) -}}
{{- end -}}

{{/* DATABASE_URL completa (usada dentro do Secret e pelo Job de migração). */}}
{{- define "mural.databaseUrl" -}}
{{- printf "postgres://%s:%s@%s:%d/%s?sslmode=disable" .Values.postgres.user .Values.db.password (include "mural.postgres.service" .) (int .Values.postgres.port) .Values.postgres.database -}}
{{- end -}}

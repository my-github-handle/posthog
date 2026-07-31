{{- define "posthog.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "posthog.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "posthog.labels" -}}
app.kubernetes.io/name: {{ include "posthog.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end -}}

{{/*
Prefix a bare Kafka topic name with .Values.kafka.topicPrefix.
Usage: {{ include "posthog.kafkaTopic" (dict "ctx" . "topic" "clickhouse_events_json") }}
Emits: posthog_clickhouse_events_json
*/}}
{{- define "posthog.kafkaTopic" -}}
{{- printf "%s%s" .ctx.Values.kafka.topicPrefix .topic -}}
{{- end -}}

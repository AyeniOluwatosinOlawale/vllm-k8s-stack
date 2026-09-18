{{/*
Expand the name of the chart.
*/}}
{{- define "vllm-stack.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "vllm-stack.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart label.
*/}}
{{- define "vllm-stack.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels applied to every resource.
*/}}
{{- define "vllm-stack.labels" -}}
helm.sh/chart: {{ include "vllm-stack.chart" . }}
app.kubernetes.io/name: {{ include "vllm-stack.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels for the vLLM deployment.
*/}}
{{- define "vllm-stack.selectorLabels" -}}
app.kubernetes.io/name: {{ include "vllm-stack.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app: vllm
{{- end }}

{{/*
Selector labels for the router deployment.
*/}}
{{- define "vllm-stack.routerSelectorLabels" -}}
app.kubernetes.io/name: {{ include "vllm-stack.name" . }}-router
app.kubernetes.io/instance: {{ .Release.Name }}
app: vllm-router
{{- end }}

{{/*
Namespace name.
*/}}
{{- define "vllm-stack.namespace" -}}
{{- .Values.namespace.name }}
{{- end }}

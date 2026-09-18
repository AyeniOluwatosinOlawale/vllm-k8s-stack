#!/usr/bin/env bash
# k8s-deploy.sh — Full vLLM stack deployment
#
# Usage:
#   ./scripts/k8s-deploy.sh [--helm] [--namespace llm-serving] [--model llama-3.1-8b]
#
# What it does:
#   1. Verifies prerequisites (kubectl, helm, GPU nodes)
#   2. Installs NVIDIA GPU Operator (if not already present)
#   3. Creates the namespace and secrets
#   4. Deploys the vLLM stack via Helm or raw manifests
#   5. Waits for pods to be ready
#   6. Runs a smoke test against the API
#   7. Prints the routing proxy URL and replica status

set -euo pipefail

# ─── Defaults ────────────────────────────────────────────────────────────────
NAMESPACE="${NAMESPACE:-llm-serving}"
HELM_RELEASE="${HELM_RELEASE:-vllm-stack}"
CHART_PATH="${CHART_PATH:-k8s/helm/vllm-stack}"
USE_HELM="${USE_HELM:-true}"
HF_TOKEN="${HF_TOKEN:-}"
VLLM_API_KEY="${VLLM_API_KEY:-}"
KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
GPU_OPERATOR_VERSION="v24.3.0"

# Colours
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()     { error "$*"; exit 1; }

# ─── Parse args ──────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --helm)           USE_HELM=true ;;
    --manifests)      USE_HELM=false ;;
    --namespace)      NAMESPACE="$2"; shift ;;
    --release)        HELM_RELEASE="$2"; shift ;;
    --hf-token)       HF_TOKEN="$2"; shift ;;
    --vllm-api-key)   VLLM_API_KEY="$2"; shift ;;
    *) die "Unknown argument: $1" ;;
  esac
  shift
done

# ─── Prerequisites ───────────────────────────────────────────────────────────
info "Checking prerequisites..."

command -v kubectl &>/dev/null || die "kubectl not found"
command -v helm    &>/dev/null || die "helm not found"

kubectl cluster-info &>/dev/null || die "Cannot reach cluster — check KUBECONFIG"

# Verify GPU nodes are available
GPU_NODES=$(kubectl get nodes -l nvidia.com/gpu.present=true --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [[ "$GPU_NODES" -lt 1 ]]; then
  warn "No GPU nodes with label nvidia.com/gpu.present=true found."
  warn "The deployment will remain pending until GPU nodes are added."
fi
info "Found $GPU_NODES GPU-labelled node(s)"

# ─── NVIDIA GPU Operator ─────────────────────────────────────────────────────
info "Checking NVIDIA GPU Operator..."
if ! kubectl get namespace gpu-operator &>/dev/null; then
  info "Installing NVIDIA GPU Operator $GPU_OPERATOR_VERSION..."
  helm repo add nvidia https://helm.ngc.nvidia.com/nvidia --force-update
  helm repo update
  helm upgrade --install gpu-operator nvidia/gpu-operator \
    --namespace gpu-operator \
    --create-namespace \
    --version "$GPU_OPERATOR_VERSION" \
    --values k8s/nvidia/gpu-operator-values.yaml \
    --wait --timeout 10m
  info "GPU Operator installed"
else
  info "GPU Operator namespace already exists — skipping install"
fi

# ─── Prometheus Operator (kube-prometheus-stack) ─────────────────────────────
info "Checking Prometheus Operator..."
if ! kubectl get namespace monitoring &>/dev/null; then
  warn "Namespace 'monitoring' not found — Prometheus Operator may not be installed."
  warn "ServiceMonitors and PrometheusRules require the Prometheus Operator."
  warn "Install with: helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack -n monitoring --create-namespace"
fi

# ─── Namespace + Secrets ─────────────────────────────────────────────────────
info "Creating namespace $NAMESPACE..."
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace "$NAMESPACE" nvidia.com/gpu.deploy.operands=true --overwrite

if [[ -z "$HF_TOKEN" ]]; then
  warn "HF_TOKEN not set — model download from HuggingFace Hub will fail."
  warn "Set it with: export HF_TOKEN=hf_xxx or pass --hf-token hf_xxx"
fi
if [[ -z "$VLLM_API_KEY" ]]; then
  VLLM_API_KEY="$(openssl rand -hex 16)"
  warn "VLLM_API_KEY not set — generated random key: $VLLM_API_KEY"
fi

info "Creating/updating vllm-secrets..."
kubectl create secret generic vllm-secrets \
  --namespace "$NAMESPACE" \
  --from-literal=HF_TOKEN="${HF_TOKEN:-PLACEHOLDER}" \
  --from-literal=VLLM_API_KEY="$VLLM_API_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -

# ─── Deploy ───────────────────────────────────────────────────────────────────
if [[ "$USE_HELM" == "true" ]]; then
  info "Deploying via Helm: $HELM_RELEASE from $CHART_PATH..."
  helm upgrade --install "$HELM_RELEASE" "$CHART_PATH" \
    --namespace "$NAMESPACE" \
    --set namespace.create=false \
    --set secrets.hfToken="${HF_TOKEN:-PLACEHOLDER}" \
    --set secrets.vllmApiKey="$VLLM_API_KEY" \
    --wait=false \
    --timeout 15m
else
  info "Deploying via raw manifests..."
  kubectl apply -f k8s/vllm/configmap.yaml
  kubectl apply -f k8s/vllm/deployment.yaml
  kubectl apply -f k8s/vllm/service.yaml
  kubectl apply -f k8s/vllm/hpa.yaml
  kubectl apply -f k8s/vllm/pdb.yaml
  if kubectl get namespace monitoring &>/dev/null; then
    kubectl apply -f k8s/observability/servicemonitor.yaml
    kubectl apply -f k8s/observability/prometheusrule.yaml
  fi
  kubectl apply -f k8s/router/configmap.yaml
  kubectl apply -f k8s/router/deployment.yaml
  kubectl apply -f k8s/router/service.yaml
  kubectl apply -f k8s/router/ingress.yaml
fi

# ─── Wait for vLLM pods ──────────────────────────────────────────────────────
info "Waiting for vLLM pods to be ready (up to 10 minutes)..."
echo "Note: First deploy takes longer — model weights need to download (~15GB for 8B)"
kubectl rollout status deployment/vllm \
  --namespace "$NAMESPACE" \
  --timeout 600s && info "vLLM deployment ready" || warn "Timeout — check pod events below"

# ─── Wait for router ─────────────────────────────────────────────────────────
info "Waiting for router pods..."
kubectl rollout status deployment/vllm-router \
  --namespace "$NAMESPACE" \
  --timeout 60s && info "Router ready" || warn "Router timeout"

# ─── Smoke test ──────────────────────────────────────────────────────────────
info "Running smoke test via port-forward..."
kubectl port-forward service/vllm-router 18080:80 \
  --namespace "$NAMESPACE" &
PF_PID=$!
sleep 3

HEALTH=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:18080/health || echo "000")
if [[ "$HEALTH" == "200" ]]; then
  info "Health check: PASS (HTTP 200)"
else
  warn "Health check: FAIL (HTTP $HEALTH)"
fi

MODELS=$(curl -s http://localhost:18080/v1/models 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print([m['id'] for m in d.get('data',[])])" 2>/dev/null || echo "parse error")
info "Available models: $MODELS"

TEST_RESP=$(curl -s -X POST http://localhost:18080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"llama-3.1-8b","messages":[{"role":"user","content":"Reply with OK only"}],"max_tokens":5}' \
  2>/dev/null)
if echo "$TEST_RESP" | grep -q '"content"'; then
  info "Inference smoke test: PASS"
  echo "$TEST_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print('Response:', d['choices'][0]['message']['content'])" 2>/dev/null || true
else
  warn "Inference smoke test: FAIL or model still loading"
  echo "Response: $TEST_RESP"
fi

kill $PF_PID 2>/dev/null || true

# ─── Status summary ──────────────────────────────────────────────────────────
echo ""
info "=== Deployment Status ==="
kubectl get pods -n "$NAMESPACE" -l app=vllm -o wide
echo ""
kubectl get pods -n "$NAMESPACE" -l app=vllm-router -o wide
echo ""
kubectl get hpa -n "$NAMESPACE"
echo ""
info "Router service: $(kubectl get svc vllm-router -n $NAMESPACE -o jsonpath='{.spec.clusterIP}')":80
info "Debug replicas: kubectl port-forward svc/vllm-router 18080:80 -n $NAMESPACE && curl localhost:18080/debug/replicas"
info "Grafana: import k8s/observability/grafana-dashboard.json into your Grafana instance"
info "Done."

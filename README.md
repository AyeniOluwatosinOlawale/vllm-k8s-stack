# Production LLM Serving Stack on Kubernetes

Deploy vLLM on Kubernetes with multiple replicas, KV-cache-aware routing, autoscaling on inference metrics, and a full Prometheus/Grafana observability stack.

**Tools:** vLLM · Kubernetes · Helm · Prometheus · Grafana · FastAPI  
**Phase:** [AI Inference Engineering Roadmap 2026](https://www.linkedin.com/posts/vishakha-sadhwani) — Phase 9: Inference on Kubernetes

---

## Architecture

```
                         ┌─────────────────────────────────┐
Internet / Client        │         nginx Ingress            │
      │                  └────────────────┬────────────────┘
      │                                   │
      ▼                  ┌────────────────▼────────────────┐
                         │     KV-Cache-Aware Router        │
                         │     (FastAPI, 2 replicas)        │
                         │                                  │
                         │  Polls /metrics every 5s        │
                         │  Score = kv_cache*0.6           │
                         │        + queue_depth*0.3        │
                         │        + active_reqs*0.1        │
                         └──────┬──────────────┬───────────┘
                                │              │
                   ┌────────────▼──┐    ┌──────▼────────────┐
                   │  vLLM Pod 0   │    │  vLLM Pod 1        │
                   │  (GPU node A) │    │  (GPU node B)      │
                   │  /metrics     │    │  /metrics          │
                   └───────────────┘    └────────────────────┘
                                │              │
                   ┌────────────▼──────────────▼────────────┐
                   │          Prometheus + Grafana           │
                   │   KV-cache · TTFT · TPOT · GPU util     │
                   └─────────────────────────────────────────┘

HPA watches:  vllm_num_requests_waiting > 5/pod  → scale up
              vllm_gpu_cache_usage_perc > 75%    → scale up
```

---

## What's Inside

```
.
├── base/
│   └── namespace.yaml              # llm-serving namespace
├── nvidia/
│   └── gpu-operator-values.yaml    # NVIDIA GPU Operator Helm values
├── vllm/
│   ├── configmap.yaml              # Engine config (model, KV-cache, chunked prefill)
│   ├── deployment.yaml             # GPU tolerations, anti-affinity, startup probes
│   ├── service.yaml                # ClusterIP + headless for per-pod metric scraping
│   ├── hpa.yaml                    # Autoscale on KV-cache fill + queue depth
│   └── pdb.yaml                    # PodDisruptionBudget — minAvailable: 1
├── router-proxy/
│   ├── main.py                     # FastAPI KV-cache-aware load balancer
│   ├── Dockerfile
│   └── requirements.txt
├── router/
│   ├── configmap.yaml
│   ├── deployment.yaml
│   ├── service.yaml
│   └── ingress.yaml                # nginx with SSE streaming + rate limiting
├── observability/
│   ├── servicemonitor.yaml         # Prometheus scrape: vLLM pods + router + DCGM
│   ├── prometheusrule.yaml         # 8 alerts (TTFT, TPOT, cache, queue, GPU, replicas)
│   └── grafana-dashboard.json      # 12-panel dashboard — import directly into Grafana
├── helm/
│   └── vllm-stack/                 # Full parameterized Helm chart
│       ├── Chart.yaml
│       ├── values.yaml             # GPU production defaults
│       ├── values-local-cpu.yaml   # CPU-only local test (no GPU needed)
│       └── templates/
└── scripts/
    ├── k8s-deploy.sh               # Full stack deploy + smoke test
    ├── k8s-load-test.sh            # 5-phase load test
    └── k8s-failure-drill.sh        # 4 failure scenarios
```

---

## Quick Start — Local (No GPU)

Test the full Kubernetes stack on your Mac using minikube and a CPU-compatible 500M model.

**Prerequisites**

```bash
brew install minikube helm
# Docker Desktop must be running
```

**1. Start a local cluster**

```bash
minikube start --driver=docker --cpus=4 --memory=8192 --disk-size=20g
```

**2. Set your secrets**

```bash
export HF_TOKEN=hf_your_token_here   # free at huggingface.co
export VLLM_API_KEY=test-key-123
```

**3. Deploy**

```bash
kubectl create namespace llm-serving
kubectl create secret generic vllm-secrets \
  --namespace llm-serving \
  --from-literal=HF_TOKEN=$HF_TOKEN \
  --from-literal=VLLM_API_KEY=$VLLM_API_KEY

helm install vllm-stack helm/vllm-stack/ \
  --namespace llm-serving \
  --values helm/vllm-stack/values-local-cpu.yaml
```

**4. Watch pods start**

```bash
kubectl get pods -n llm-serving -w
# Wait until STATUS = Running (2-5 minutes — model download)
```

**5. Test the API**

```bash
kubectl port-forward svc/vllm-router 18080:80 -n llm-serving &

curl http://localhost:18080/health
curl http://localhost:18080/v1/models
curl -X POST http://localhost:18080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen-0.5b","messages":[{"role":"user","content":"What is KV-cache?"}],"max_tokens":100}'
```

**6. Run the load test**

```bash
export VLLM_ENDPOINT=http://localhost:18080
./scripts/k8s-load-test.sh
```

**7. Run failure drills**

```bash
./scripts/k8s-failure-drill.sh --scenario pod-kill
./scripts/k8s-failure-drill.sh --scenario rolling-update
./scripts/k8s-failure-drill.sh --scenario cold-start
```

---

## Cloud Deploy — GPU Cluster

Three provider-specific values files are included. Pick the one that matches your setup.

### Option A — Google GKE (L4 GPU, ~$0.30/hr spot)

```bash
# 1. Create cluster + GPU node pool
gcloud container clusters create vllm-cluster --zone us-central1-a --num-nodes 1
gcloud container node-pools create gpu-pool \
  --cluster vllm-cluster --zone us-central1-a \
  --machine-type g2-standard-4 \
  --accelerator type=nvidia-l4,count=1,gpu-driver-version=latest \
  --num-nodes 2 --spot

# 2. Point kubectl at the new cluster
gcloud container clusters get-credentials vllm-cluster --zone us-central1-a

# 3. Install supporting components
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm install gpu-operator nvidia/gpu-operator \
  --namespace gpu-operator --create-namespace \
  --values nvidia/gpu-operator-values.yaml

helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace

helm install prometheus-adapter prometheus-community/prometheus-adapter \
  --namespace monitoring \
  --set prometheus.url=http://kube-prometheus-stack-prometheus.monitoring.svc

# 4. Deploy vLLM stack
export HF_TOKEN=hf_your_token_here
export VLLM_API_KEY=$(openssl rand -hex 16)

helm install vllm-stack helm/vllm-stack/ \
  --namespace llm-serving --create-namespace \
  --values helm/vllm-stack/values-cloud-gke.yaml \
  --set secrets.hfToken=$HF_TOKEN \
  --set secrets.vllmApiKey=$VLLM_API_KEY
```

### Option B — Amazon EKS (T4 GPU, ~$0.53/hr)

```bash
# 1. Create cluster
eksctl create cluster --name vllm-cluster --region us-east-1 \
  --nodegroup-name gpu-nodes --node-type g4dn.xlarge \
  --nodes 2 --nodes-min 1 --nodes-max 4 --managed --asg-access

# 2. Install NVIDIA device plugin
kubectl apply -f https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.15.0/deployments/static/nvidia-device-plugin.yml

# 3. Install GPU Operator + Prometheus stack (same as GKE above)

# 4. Deploy
helm install vllm-stack helm/vllm-stack/ \
  --namespace llm-serving --create-namespace \
  --values helm/vllm-stack/values-cloud-eks.yaml \
  --set secrets.hfToken=$HF_TOKEN \
  --set secrets.vllmApiKey=$VLLM_API_KEY
```

### Option C — RunPod (cheapest GPU, ~$0.20-0.50/hr) ← recommended for this lab

RunPod is the fastest way to get a real GPU for testing without a cloud account setup.

```bash
# 1. Go to runpod.io → Pods → Deploy
#    Choose: Kubernetes Worker → RTX 4090 or A40
#    Download the kubeconfig file

# 2. Point kubectl at RunPod
export KUBECONFIG=~/Downloads/runpod-kubeconfig.yaml
kubectl get nodes   # verify GPU node appears

# 3. Deploy — no Prometheus Operator needed, keep it simple
helm install vllm-stack helm/vllm-stack/ \
  --namespace llm-serving --create-namespace \
  --values helm/vllm-stack/values-cloud-runpod.yaml \
  --set secrets.hfToken=$HF_TOKEN \
  --set secrets.vllmApiKey=$VLLM_API_KEY

# 4. Get the public IP assigned to the router LoadBalancer
kubectl get svc vllm-router -n llm-serving
# EXTERNAL-IP will appear after ~60s

export VLLM_ENDPOINT=http://<EXTERNAL-IP>
```

### Post-deploy (all cloud options)

```bash
# Watch pods come up (model download takes 5-10 min first time)
kubectl get pods -n llm-serving -w

# Smoke test
curl $VLLM_ENDPOINT/health
curl $VLLM_ENDPOINT/v1/models

# Full load test
./scripts/k8s-load-test.sh

# Failure drills
./scripts/k8s-failure-drill.sh --scenario pod-kill
./scripts/k8s-failure-drill.sh --scenario rolling-update
./scripts/k8s-failure-drill.sh --scenario cold-start

# Check routing decisions in real time
curl $VLLM_ENDPOINT/debug/replicas | python3 -m json.tool

# Watch HPA respond to load
kubectl get hpa -n llm-serving -w
```

### Teardown (stop billing)

```bash
# Helm uninstall
helm uninstall vllm-stack --namespace llm-serving

# GKE: delete node pool
gcloud container node-pools delete gpu-pool --cluster vllm-cluster --zone us-central1-a

# EKS: delete cluster
eksctl delete cluster --name vllm-cluster --region us-east-1

# RunPod: stop the pod from the dashboard
```

---

## Observability

**Grafana dashboard** — import `observability/grafana-dashboard.json`

Panels:
| Panel | Metric |
|---|---|
| KV-cache fill (gauge) | `vllm:gpu_cache_usage_perc` |
| KV-cache over time | GPU + CPU cache fill per pod |
| Queue depth | Running / waiting / swapped requests |
| Throughput | tokens/sec and req/sec |
| TTFT P50/P90/P99 | `vllm:time_to_first_token_seconds` |
| TPOT P50/P90/P99 | `vllm:time_per_output_token_seconds` |
| GPU utilization | DCGM `DCGM_FI_DEV_GPU_UTIL` |
| GPU memory | DCGM free vs used |
| Routing scores | Per-replica composite score |
| Replica health | 1 = healthy, 0 = unhealthy |

**Alerts** — fire to your AlertManager:
- `VLLMHighKVCacheUsage` — cache > 85% for 5m → warning
- `VLLMCriticalKVCacheUsage` — cache > 95% for 1m → critical
- `VLLMHighQueueDepth` — 20+ waiting requests for 2m → warning
- `VLLMHighTTFT` — P99 TTFT > 5s for 3m → warning
- `VLLMHighTPOT` — P99 TPOT > 200ms for 3m → warning
- `VLLMReplicaDown` — 0 ready replicas → critical
- `VLLMGPUSaturated` — GPU at 98%+ for 10m → warning

---

## KV-Cache-Aware Routing

The routing proxy (`router-proxy/main.py`) polls `/metrics` from every vLLM replica every 5 seconds and routes each request to the replica with the most available capacity:

```
score = (kv_cache_usage × 0.6) + (queue_depth/10 × 0.3) + (active_reqs/50 × 0.1)
```

Lower score = more capacity = preferred. The 0.6 weight on `kv_cache_usage` is intentional: a nearly-full KV-cache causes sequence evictions that degrade *all* in-flight requests, not just new ones — so avoiding cache-pressured replicas is the primary routing concern.

**Model-aware routing** — set `REPLICA_POOLS` in the router ConfigMap to route different model names to separate replica pools:

```json
{
  "llama-3.1-8b": ["http://vllm-0.vllm-headless:8000", "http://vllm-1.vllm-headless:8000"],
  "mistral-7b":   ["http://vllm-mistral-0.vllm-mistral-headless:8000"]
}
```

---

## Autoscaling

The HPA scales the vLLM Deployment on two signals simultaneously:

| Signal | Target | Meaning |
|---|---|---|
| `vllm_num_requests_waiting` | 5 per pod | Queue is building — add capacity |
| `vllm_gpu_cache_usage_perc` | 75% (750m) | Cache pressure — add capacity |

Whichever metric recommends more replicas wins. Scale-in waits 5 minutes (stabilization window) to avoid flapping during bursty traffic.

Requires [prometheus-adapter](https://github.com/kubernetes-sigs/prometheus-adapter) to expose vLLM's Prometheus metrics as Kubernetes custom metrics. The adapter ConfigMap is included in `vllm/hpa.yaml`.

---

## Load Test Phases

`scripts/k8s-load-test.sh` runs 5 phases and saves JSON results to `load_test_results/`:

| Phase | What it tests |
|---|---|
| 1. Baseline | Single sequential requests — raw TTFT and TPOT |
| 2. Concurrency ramp | 1 → 4 → 8 → 16 concurrent clients — latency-throughput curve |
| 3. Sustained load | 8 concurrent clients for ~120s — steady-state behaviour |
| 4. Prefix caching | Cold vs warm requests with shared system prompt — cache hit rate |
| 5. KV-cache pressure | Long-context requests — observe eviction, HPA trigger, recovery |

---

## Failure Drill Scenarios

`scripts/k8s-failure-drill.sh` injects failures under live load and measures recovery:

| Scenario | What happens | Pass condition |
|---|---|---|
| Pod kill | Delete one vLLM pod instantly | ≤1 probe error during failover |
| Rolling update | Restart all pods one-by-one | 0 dropped requests (maxSurge=1, maxUnavailable=0) |
| Cold start | Scale → 0 → 2, measure time to ready | First request within 300s |
| Node drain | Cordon + drain GPU node | PDB holds; pod rescheduled on another node |

---

## Key Design Decisions

**Why `maxUnavailable: 0, maxSurge: 1`?**
vLLM takes 60-120s to load a model. If the old pod is killed before the new one is ready, there's a gap with zero serving capacity. `maxUnavailable: 0` prevents that — the new pod must pass its readiness probe before the old one is removed.

**Why a headless service alongside ClusterIP?**
The ClusterIP service is for routing (kube-proxy load balances across pods). The headless service returns individual pod IPs via DNS, which the routing proxy needs to poll `/metrics` per-replica independently.

**Why KV-cache as the primary routing signal (60% weight)?**
A full KV-cache doesn't just slow *new* requests — it forces the engine to evict cached sequences, which stalls decode for *already-running* requests too. Routing away from cache-pressured replicas protects existing users, not just new ones.

**Why HPA fires on both queue depth *and* cache fill?**
Queue depth alone misses the case where a replica is slow (not queuing) but saturated. Cache fill alone misses the case where cache is low but requests are piling up. Both signals together cover the failure modes.

---

## Requirements

| Tool | Version | Purpose |
|---|---|---|
| Kubernetes | ≥ 1.28 | Container orchestration |
| Helm | ≥ 3.12 | Chart templating and deploy |
| NVIDIA GPU Operator | ≥ v24.3 | GPU device plugin + DCGM exporter |
| Prometheus Operator | ≥ 0.70 | ServiceMonitor + PrometheusRule CRDs |
| prometheus-adapter | ≥ 0.11 | Custom metrics API for HPA |
| nginx ingress controller | any | Ingress + streaming proxy |
| vLLM | 0.6.3 (pinned) | LLM inference engine |
| HuggingFace token | — | Model weight download |

---

## Part of a Larger Roadmap

This is Phase 9 of a 13-phase [AI Inference Engineering Roadmap](https://www.linkedin.com/posts/vishakha-sadhwani):

| # | Phase | Status |
|---|---|---|
| 1–8 | Fundamentals → Distributed Inference | ✅ |
| **9** | **Inference on Kubernetes** | **← this repo** |
| 10 | Inference Networking | — |
| 11 | Inference Observability | — |
| 12 | Production AI Inference | — |
| 13 | Real-World Projects & Career | — |

# Benchmark Results — Qwen3-8B on RunPod RTX 4090

**Date:** 2026-09-18  
**Phase:** 9 — Production LLM Serving Stack on Kubernetes

## Environment

| Parameter | Value |
|---|---|
| Provider | RunPod (Secure Cloud) |
| GPU | NVIDIA GeForce RTX 4090 (48GB VRAM) |
| CUDA | 13.2 |
| vLLM | v0.8.5 |
| Model | Qwen/Qwen3-8B |
| Precision | BF16 |
| Max sequence length | 8192 |
| GPU memory utilization | 90% |
| Prefix caching | enabled |
| Chunked prefill | enabled |

## Smoke Test Results

| Endpoint | Result |
|---|---|
| `GET /health` | ✅ 200 OK |
| `GET /v1/models` | ✅ Returns `qwen3-8b` |
| `POST /v1/chat/completions` (non-streaming) | ✅ Working |
| `POST /v1/chat/completions` (streaming SSE) | ✅ Working |

## Throughput

| Metric | Value |
|---|---|
| Prompt tokens | 21 |
| Completion tokens | 150 |
| Total wall time | 2.733s |
| **Throughput** | **~55 tok/s** |

> Note: Qwen3-8B runs in thinking mode by default (`<think>` chain-of-thought). The 150 completion tokens are internal reasoning tokens. Pass `"chat_template_kwargs": {"enable_thinking": false}` to get direct answers, which would yield higher effective throughput (~80-100 tok/s).

## Model Load Stats

| Metric | Value |
|---|---|
| Model download time | 13.1s (RunPod NVMe) |
| Model size on GPU | 15.27 GiB |
| Load time | 16.97s |
| CUDA graph compile (first run) | ~45s (cached after) |
| Total startup time | ~120s |

## Streaming Output Sample

Qwen3-8B produces OpenAI-compatible SSE chunks:

```
data: {"id":"chatcmpl-...","object":"chat.completion.chunk","model":"qwen3-8b",
       "choices":[{"delta":{"content":"<think>"},"finish_reason":null}]}
data: {"id":"chatcmpl-...","choices":[{"delta":{"content":"Okay,"},"finish_reason":null}]}
...
data: [DONE]
```

## Notes

- RunPod GPU pods run as Docker containers — k3s cannot run inside them (bind-mount/sysctl restrictions)
- vLLM was served directly (`python -m vllm.entrypoints.openai.api_server`) rather than via Helm chart
- The Helm chart deploys correctly on real Kubernetes clusters (EKS, GKE, AKS) with VM-backed nodes
- Dependency pinning required: `transformers<5.0`, `numpy<2.3` for vLLM 0.8.5 compatibility

"""
KV-Cache-Aware vLLM Load Balancer

Routes OpenAI-compatible inference requests to the vLLM replica that has the
most available capacity, measured by KV-cache fill ratio and queue depth.

Routing algorithm per request:
  1. Parse `model` field from the request body.
  2. Look up the replica pool that serves that model alias.
  3. Score each healthy replica in the pool:
       score = (kv_cache_usage * 0.6) + (queue_depth_norm * 0.3) + (running_norm * 0.1)
     Lower score = more capacity available = preferred replica.
  4. Forward the request to the lowest-scored replica.
  5. On upstream error (5xx / connection refused), retry on the next-best replica.

Metrics collection:
  A background task polls /metrics on every known replica every POLL_INTERVAL_S
  seconds, parses Prometheus text format, and stores the latest snapshot.
  Replicas that fail 3 consecutive polls are marked unhealthy and excluded
  from routing until they recover.

Model-aware routing:
  Set REPLICA_POOLS env var to a JSON object mapping model aliases to lists
  of replica base URLs:
    {"llama-3.1-8b": ["http://vllm-0.vllm-headless:8000",
                       "http://vllm-1.vllm-headless:8000"],
     "mistral-7b":   ["http://vllm-mistral-0.vllm-mistral-headless:8000"]}

  If REPLICA_POOLS is not set, the router falls back to auto-discovery using
  the headless service DNS pattern: vllm-{0..N}.vllm-headless.llm-serving.svc.
"""
from __future__ import annotations

import asyncio
import json
import logging
import os
import time
from dataclasses import dataclass, field
from typing import Any

import httpx
from fastapi import FastAPI, HTTPException, Request, Response
from fastapi.responses import StreamingResponse
from prometheus_client import (
    Counter,
    Gauge,
    Histogram,
    generate_latest,
    CONTENT_TYPE_LATEST,
)

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("vllm-router")

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

POLL_INTERVAL_S = float(os.getenv("POLL_INTERVAL_S", "5"))
UNHEALTHY_THRESHOLD = int(os.getenv("UNHEALTHY_THRESHOLD", "3"))
REQUEST_TIMEOUT_S = float(os.getenv("REQUEST_TIMEOUT_S", "300"))
MAX_RETRIES = int(os.getenv("MAX_RETRIES", "2"))

# JSON mapping of model alias → list of replica base URLs.
# Falls back to single-pool discovery if not set.
REPLICA_POOLS_JSON = os.getenv("REPLICA_POOLS", "")

# Fallback: headless DNS discovery for a single deployment named "vllm"
VLLM_HEADLESS_NAMESPACE = os.getenv("VLLM_HEADLESS_NAMESPACE", "llm-serving")
VLLM_REPLICA_COUNT = int(os.getenv("VLLM_REPLICA_COUNT", "2"))
VLLM_MODEL_ALIAS = os.getenv("VLLM_MODEL_ALIAS", "llama-3.1-8b")

# ---------------------------------------------------------------------------
# Prometheus metrics (this proxy exports its own /metrics)
# ---------------------------------------------------------------------------

REQUESTS_TOTAL = Counter(
    "router_requests_total",
    "Total proxied requests",
    ["model", "replica", "status"],
)
REQUEST_DURATION = Histogram(
    "router_request_duration_seconds",
    "End-to-end request duration",
    ["model", "replica"],
    buckets=[0.1, 0.25, 0.5, 1, 2, 5, 10, 30, 60, 120, 300],
)
REPLICA_KV_CACHE = Gauge(
    "router_replica_kv_cache_usage",
    "KV-cache fill ratio reported by each replica (0-1)",
    ["replica"],
)
REPLICA_QUEUE_DEPTH = Gauge(
    "router_replica_queue_depth",
    "Waiting requests per replica",
    ["replica"],
)
REPLICA_ACTIVE = Gauge(
    "router_replica_active_requests",
    "Running requests per replica",
    ["replica"],
)
REPLICA_HEALTHY = Gauge(
    "router_replica_healthy",
    "1 if replica is healthy, 0 if unhealthy",
    ["replica"],
)
ROUTING_SCORE = Gauge(
    "router_replica_routing_score",
    "Composite routing score (lower = more capacity)",
    ["replica"],
)

# ---------------------------------------------------------------------------
# Data model
# ---------------------------------------------------------------------------

@dataclass
class ReplicaMetrics:
    base_url: str
    kv_cache_usage: float = 0.0       # 0.0 – 1.0
    num_requests_running: float = 0.0
    num_requests_waiting: float = 0.0
    consecutive_failures: int = 0
    last_seen: float = field(default_factory=time.monotonic)

    @property
    def healthy(self) -> bool:
        return self.consecutive_failures < UNHEALTHY_THRESHOLD

    def routing_score(self) -> float:
        """
        Lower score → preferred replica.

        Weights:
          60% KV-cache fill — the primary capacity signal.
              A nearly-full cache causes evictions that stall other requests.
          30% Normalised queue depth — each waiting request blocks a future slot.
          10% Normalised active count — mild preference for less-loaded replicas.
        """
        kv = self.kv_cache_usage
        queue = min(self.num_requests_waiting / 10.0, 1.0)   # saturate at 10
        active = min(self.num_requests_running / 50.0, 1.0)  # saturate at 50
        return kv * 0.6 + queue * 0.3 + active * 0.1


# ---------------------------------------------------------------------------
# Replica registry
# ---------------------------------------------------------------------------

class ReplicaRegistry:
    """Thread-safe store of per-replica metrics, updated by the poll loop."""

    def __init__(self, pools: dict[str, list[str]]) -> None:
        self._pools = pools  # model alias → [base_url]
        self._metrics: dict[str, ReplicaMetrics] = {
            url: ReplicaMetrics(base_url=url)
            for urls in pools.values()
            for url in urls
        }

    def all_urls(self) -> list[str]:
        return list(self._metrics.keys())

    def get(self, url: str) -> ReplicaMetrics:
        return self._metrics[url]

    def update(self, url: str, **kwargs: Any) -> None:
        m = self._metrics[url]
        for k, v in kwargs.items():
            setattr(m, k, v)
        m.last_seen = time.monotonic()

    def mark_failure(self, url: str) -> None:
        self._metrics[url].consecutive_failures += 1

    def mark_success(self, url: str) -> None:
        self._metrics[url].consecutive_failures = 0

    def best_replica_for_model(self, model_alias: str) -> str | None:
        """Return the URL of the best replica for this model alias."""
        # Find the right pool, fall back to any pool if alias not found.
        candidates = self._pools.get(model_alias) or list(self.all_urls())
        healthy = [u for u in candidates if self._metrics[u].healthy]
        if not healthy:
            log.warning("No healthy replicas for model %s; trying all", model_alias)
            healthy = candidates
        if not healthy:
            return None
        return min(healthy, key=lambda u: self._metrics[u].routing_score())


# ---------------------------------------------------------------------------
# Metrics poller
# ---------------------------------------------------------------------------

async def poll_replica(client: httpx.AsyncClient, registry: ReplicaRegistry, url: str) -> None:
    """Fetch /metrics from one replica and update the registry."""
    try:
        resp = await client.get(f"{url}/metrics", timeout=5.0)
        resp.raise_for_status()
        m = parse_prometheus_text(resp.text)
        registry.update(
            url,
            kv_cache_usage=m.get("vllm:gpu_cache_usage_perc", 0.0),
            num_requests_running=m.get("vllm:num_requests_running", 0.0),
            num_requests_waiting=m.get("vllm:num_requests_waiting", 0.0),
        )
        registry.mark_success(url)

        r = registry.get(url)
        label = url.split("//")[-1]
        REPLICA_KV_CACHE.labels(replica=label).set(r.kv_cache_usage)
        REPLICA_QUEUE_DEPTH.labels(replica=label).set(r.num_requests_waiting)
        REPLICA_ACTIVE.labels(replica=label).set(r.num_requests_running)
        REPLICA_HEALTHY.labels(replica=label).set(1)
        ROUTING_SCORE.labels(replica=label).set(r.routing_score())

    except Exception as exc:
        registry.mark_failure(url)
        label = url.split("//")[-1]
        REPLICA_HEALTHY.labels(replica=label).set(
            0 if not registry.get(url).healthy else 1
        )
        log.warning("Poll failed for %s (failure #%d): %s",
                    url, registry.get(url).consecutive_failures, exc)


def parse_prometheus_text(text: str) -> dict[str, float]:
    """
    Minimal Prometheus text format parser — extracts gauge/counter values by name.
    Only handles simple `metric_name value` lines; ignores labels and histograms.
    """
    result: dict[str, float] = {}
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("#") or not line:
            continue
        parts = line.rsplit(" ", 1)
        if len(parts) == 2:
            raw_name = parts[0].split("{")[0].strip()
            try:
                result[raw_name] = float(parts[1])
            except ValueError:
                pass
    return result


async def metrics_poll_loop(registry: ReplicaRegistry) -> None:
    """Background task: poll all replicas every POLL_INTERVAL_S seconds."""
    async with httpx.AsyncClient() as client:
        while True:
            tasks = [
                poll_replica(client, registry, url)
                for url in registry.all_urls()
            ]
            await asyncio.gather(*tasks, return_exceptions=True)
            await asyncio.sleep(POLL_INTERVAL_S)


# ---------------------------------------------------------------------------
# FastAPI application
# ---------------------------------------------------------------------------

app = FastAPI(title="vLLM KV-Cache-Aware Router", version="1.0.0")

registry: ReplicaRegistry | None = None


@app.on_event("startup")
async def startup() -> None:
    global registry

    if REPLICA_POOLS_JSON:
        pools = json.loads(REPLICA_POOLS_JSON)
    else:
        # Auto-build pool from headless service DNS.
        # StatefulSet pods are addressable as: {pod-name}.{headless-svc}.{namespace}.svc
        # For a Deployment we enumerate pod indices 0..N-1 (assumes stable names aren't
        # guaranteed — prefer setting REPLICA_POOLS explicitly in production).
        urls = [
            f"http://vllm-{i}.vllm-headless.{VLLM_HEADLESS_NAMESPACE}.svc:8000"
            for i in range(VLLM_REPLICA_COUNT)
        ]
        pools = {VLLM_MODEL_ALIAS: urls}

    log.info("Router starting with pools: %s", json.dumps(pools, indent=2))
    registry = ReplicaRegistry(pools)
    asyncio.create_task(metrics_poll_loop(registry))


@app.get("/health")
async def health() -> dict:
    if registry is None:
        raise HTTPException(status_code=503, detail="registry not initialised")
    healthy = [u for u in registry.all_urls() if registry.get(u).healthy]
    if not healthy:
        raise HTTPException(status_code=503, detail="no healthy replicas")
    return {"status": "ok", "healthy_replicas": len(healthy)}


@app.get("/metrics")
async def metrics_endpoint() -> Response:
    """Expose this proxy's own Prometheus metrics."""
    return Response(content=generate_latest(), media_type=CONTENT_TYPE_LATEST)


@app.get("/v1/models")
async def list_models(request: Request) -> Response:
    """Aggregate /v1/models responses from all healthy replicas."""
    assert registry is not None
    healthy = [u for u in registry.all_urls() if registry.get(u).healthy]
    if not healthy:
        raise HTTPException(status_code=503, detail="no healthy replicas")
    async with httpx.AsyncClient() as client:
        try:
            resp = await client.get(f"{healthy[0]}/v1/models", timeout=10.0,
                                    headers=dict(request.headers))
            return Response(content=resp.content, status_code=resp.status_code,
                            media_type="application/json")
        except Exception as e:
            raise HTTPException(status_code=502, detail=str(e))


async def _proxy_request(request: Request, path: str) -> Response:
    """
    Core proxy logic:
      1. Parse model alias from request body.
      2. Pick best replica using KV-cache scoring.
      3. Forward request; retry on failure.
      4. Stream response back to client.
    """
    assert registry is not None

    body = await request.body()
    model_alias = "default"
    try:
        body_json = json.loads(body)
        model_alias = body_json.get("model", "default")
    except (json.JSONDecodeError, AttributeError):
        pass

    excluded: set[str] = set()
    last_error: Exception | None = None

    for attempt in range(MAX_RETRIES + 1):
        # Choose the best available replica excluding already-failed ones.
        all_candidates = [
            u for u in (registry._pools.get(model_alias) or registry.all_urls())
            if u not in excluded
        ]
        if not all_candidates:
            log.error("All replicas exhausted after %d attempts", attempt)
            raise HTTPException(status_code=502, detail="all replicas failed")

        target = min(
            [u for u in all_candidates if registry.get(u).healthy] or all_candidates,
            key=lambda u: registry.get(u).routing_score(),
        )
        replica_label = target.split("//")[-1]
        upstream_url = f"{target}/{path}"

        t0 = time.monotonic()
        try:
            is_streaming = body_json.get("stream", False) if body else False

            if is_streaming:
                return await _stream_response(
                    request, upstream_url, body, model_alias, replica_label, t0
                )

            async with httpx.AsyncClient() as client:
                resp = await client.request(
                    method=request.method,
                    url=upstream_url,
                    content=body,
                    headers={k: v for k, v in request.headers.items()
                              if k.lower() not in ("host", "content-length")},
                    timeout=REQUEST_TIMEOUT_S,
                )
            duration = time.monotonic() - t0
            status_class = str(resp.status_code // 100) + "xx"
            REQUESTS_TOTAL.labels(model=model_alias, replica=replica_label,
                                   status=status_class).inc()
            REQUEST_DURATION.labels(model=model_alias, replica=replica_label).observe(duration)

            if resp.status_code >= 500:
                excluded.add(target)
                last_error = Exception(f"HTTP {resp.status_code} from {target}")
                log.warning("Replica %s returned %d, retrying", target, resp.status_code)
                continue

            return Response(
                content=resp.content,
                status_code=resp.status_code,
                headers=dict(resp.headers),
            )

        except (httpx.ConnectError, httpx.ReadTimeout, httpx.RemoteProtocolError) as e:
            excluded.add(target)
            last_error = e
            log.warning("Replica %s connection error (attempt %d): %s", target, attempt + 1, e)
            registry.mark_failure(target)

    raise HTTPException(status_code=502, detail=f"All retries failed: {last_error}")


async def _stream_response(
    request: Request,
    upstream_url: str,
    body: bytes,
    model_alias: str,
    replica_label: str,
    t0: float,
) -> StreamingResponse:
    """Stream SSE tokens back to the client as they arrive from vLLM."""
    headers = {k: v for k, v in request.headers.items()
               if k.lower() not in ("host", "content-length")}

    async def generate():
        async with httpx.AsyncClient() as client:
            async with client.stream(
                method=request.method,
                url=upstream_url,
                content=body,
                headers=headers,
                timeout=REQUEST_TIMEOUT_S,
            ) as resp:
                async for chunk in resp.aiter_bytes():
                    yield chunk
        duration = time.monotonic() - t0
        REQUESTS_TOTAL.labels(model=model_alias, replica=replica_label, status="2xx").inc()
        REQUEST_DURATION.labels(model=model_alias, replica=replica_label).observe(duration)

    return StreamingResponse(
        generate(),
        media_type="text/event-stream",
        headers={"X-Routed-To": replica_label, "Cache-Control": "no-cache"},
    )


@app.post("/v1/chat/completions")
async def chat_completions(request: Request) -> Response:
    return await _proxy_request(request, "v1/chat/completions")


@app.post("/v1/completions")
async def completions(request: Request) -> Response:
    return await _proxy_request(request, "v1/completions")


@app.post("/v1/embeddings")
async def embeddings(request: Request) -> Response:
    return await _proxy_request(request, "v1/embeddings")


# Debug endpoint: inspect current replica state (not for production exposure).
@app.get("/debug/replicas")
async def debug_replicas() -> dict:
    assert registry is not None
    return {
        url: {
            "healthy": registry.get(url).healthy,
            "kv_cache_usage": registry.get(url).kv_cache_usage,
            "num_requests_running": registry.get(url).num_requests_running,
            "num_requests_waiting": registry.get(url).num_requests_waiting,
            "routing_score": registry.get(url).routing_score(),
            "consecutive_failures": registry.get(url).consecutive_failures,
        }
        for url in registry.all_urls()
    }

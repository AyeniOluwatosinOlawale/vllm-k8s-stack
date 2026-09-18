#!/usr/bin/env bash
# k8s-load-test.sh — Multi-phase load test for the vLLM Kubernetes stack
#
# Phases:
#   1. Baseline    — single request, measure TTFT and TPOT
#   2. Ramp        — sweep concurrency 1 → 4 → 8 → 16, measure throughput
#   3. Sustained   — hold 8 concurrent clients for 2 minutes
#   4. KV-cache    — send requests with a shared system prompt to exercise prefix caching
#   5. KV-pressure — long-context requests to fill the KV-cache and observe HPA
#
# Output:
#   - Per-phase JSON results in load_test_results/
#   - Final summary table printed to stdout
#
# Dependencies: curl, jq, python3 (stdlib only)
#
# Usage:
#   export VLLM_ENDPOINT=http://localhost:18080   # from port-forward or Ingress
#   export VLLM_API_KEY=your-key
#   ./scripts/k8s-load-test.sh

set -euo pipefail

ENDPOINT="${VLLM_ENDPOINT:-http://localhost:18080}"
API_KEY="${VLLM_API_KEY:-}"
MODEL="${VLLM_MODEL:-llama-3.1-8b}"
RESULTS_DIR="load_test_results/$(date +%Y%m%d_%H%M%S)"
mkdir -p "$RESULTS_DIR"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
phase() { echo -e "\n${CYAN}=== Phase: $* ===${NC}"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }

AUTH_HEADER=""
[[ -n "$API_KEY" ]] && AUTH_HEADER="-H \"Authorization: Bearer $API_KEY\""

# ─── Helper: single timed request ─────────────────────────────────────────────
# Returns: json with ttft_s, total_s, tokens, error
timed_request() {
  local prompt="$1"
  local max_tokens="${2:-100}"
  local stream="${3:-false}"

  local start_ms
  start_ms=$(date +%s%3N)

  local body
  body=$(jq -nc \
    --arg model "$MODEL" \
    --arg prompt "$prompt" \
    --argjson max_tokens "$max_tokens" \
    --argjson stream "$stream" \
    '{model: $model,
      messages: [{role: "user", content: $prompt}],
      max_tokens: $max_tokens,
      stream: $stream}')

  local resp http_code
  if [[ "$stream" == "true" ]]; then
    # Streaming: measure TTFT as time to first data chunk
    local first_chunk_ms=""
    local full_response=""
    local output_tokens=0

    while IFS= read -r line; do
      if [[ "$line" == data:* && "$line" != "data: [DONE]" ]]; then
        if [[ -z "$first_chunk_ms" ]]; then
          first_chunk_ms=$(date +%s%3N)
        fi
        local chunk_data
        chunk_data="${line#data: }"
        local delta
        delta=$(echo "$chunk_data" | jq -r '.choices[0].delta.content // ""' 2>/dev/null || true)
        full_response+="$delta"
        ((output_tokens++)) || true
      fi
    done < <(curl -sN \
      -H "Content-Type: application/json" \
      ${API_KEY:+-H "Authorization: Bearer $API_KEY"} \
      -d "$body" \
      "$ENDPOINT/v1/chat/completions" 2>/dev/null)

    local end_ms
    end_ms=$(date +%s%3N)
    local ttft_ms=$(( first_chunk_ms - start_ms ))
    local total_ms=$(( end_ms - start_ms ))

    echo "{\"ttft_s\": $(echo "scale=3; $ttft_ms/1000" | bc), \"total_s\": $(echo "scale=3; $total_ms/1000" | bc), \"output_tokens\": $output_tokens, \"error\": null}"
  else
    resp=$(curl -s -w "\n%{http_code}" \
      -H "Content-Type: application/json" \
      ${API_KEY:+-H "Authorization: Bearer $API_KEY"} \
      -d "$body" \
      "$ENDPOINT/v1/chat/completions" 2>/dev/null)

    http_code=$(echo "$resp" | tail -1)
    local body_resp
    body_resp=$(echo "$resp" | head -n -1)

    local end_ms
    end_ms=$(date +%s%3N)
    local total_ms=$(( end_ms - start_ms ))

    if [[ "$http_code" != "200" ]]; then
      echo "{\"ttft_s\": null, \"total_s\": $(echo "scale=3; $total_ms/1000" | bc), \"output_tokens\": 0, \"error\": \"HTTP $http_code\"}"
      return
    fi

    local output_tokens
    output_tokens=$(echo "$body_resp" | jq '.usage.completion_tokens // 0' 2>/dev/null || echo 0)
    echo "{\"ttft_s\": $(echo "scale=3; $total_ms/1000" | bc), \"total_s\": $(echo "scale=3; $total_ms/1000" | bc), \"output_tokens\": $output_tokens, \"error\": null}"
  fi
}

# ─── Helper: concurrent requests ──────────────────────────────────────────────
run_concurrent() {
  local concurrency="$1"
  local num_requests="$2"
  local prompt="$3"
  local max_tokens="${4:-100}"

  local pids=()
  local result_files=()
  local start_ms
  start_ms=$(date +%s%3N)

  for i in $(seq 1 "$num_requests"); do
    local tmpfile
    tmpfile=$(mktemp)
    result_files+=("$tmpfile")
    (
      timed_request "$prompt" "$max_tokens" "true" > "$tmpfile"
    ) &
    pids+=($!)

    # Control concurrency
    if (( i % concurrency == 0 )); then
      wait "${pids[@]}"
      pids=()
    fi
  done
  wait "${pids[@]}" 2>/dev/null || true

  local end_ms
  end_ms=$(date +%s%3N)
  local wall_s
  wall_s=$(echo "scale=3; ($end_ms - $start_ms)/1000" | bc)

  # Aggregate results
  python3 - "${result_files[@]}" "$wall_s" <<'PYEOF'
import json, sys, statistics

files = sys.argv[1:-1]
wall_s = float(sys.argv[-1])
results = []
for f in files:
    try:
        with open(f) as fh:
            results.append(json.load(fh))
    except Exception:
        pass

successes = [r for r in results if r.get("error") is None]
total_tokens = sum(r.get("output_tokens", 0) for r in successes)
latencies = [r["total_s"] for r in successes]

summary = {
    "total_requests": len(results),
    "successful": len(successes),
    "failed": len(results) - len(successes),
    "wall_s": wall_s,
    "tokens_total": total_tokens,
    "tokens_per_sec": round(total_tokens / wall_s, 2) if wall_s > 0 else 0,
    "req_per_sec": round(len(successes) / wall_s, 2) if wall_s > 0 else 0,
    "latency_p50_s": round(statistics.median(latencies), 3) if latencies else None,
    "latency_p90_s": round(sorted(latencies)[int(len(latencies) * 0.9)], 3) if latencies else None,
    "latency_p99_s": round(sorted(latencies)[int(len(latencies) * 0.99)], 3) if latencies else None,
    "latency_mean_s": round(statistics.mean(latencies), 3) if latencies else None,
}
print(json.dumps(summary, indent=2))
PYEOF

  rm -f "${result_files[@]}"
}

# ─── Phase 1: Baseline ────────────────────────────────────────────────────────
phase "1 — Baseline (single request, streaming)"
info "Warming up with a single request..."
WARM=$(timed_request "Say hello in exactly three words." 20 "true")
echo "Warmup: $WARM"

info "Baseline measurement (10 sequential requests)..."
BASELINE_FILE="$RESULTS_DIR/phase1_baseline.json"
BASELINE_RESULTS=()
for i in $(seq 1 10); do
  r=$(timed_request "What is 2 + 2? Answer briefly." 20 "true")
  BASELINE_RESULTS+=("$r")
  echo "  Request $i: $(echo "$r" | jq -r '"TTFT=\(.ttft_s)s total=\(.total_s)s tokens=\(.output_tokens)"')"
done
printf '%s\n' "${BASELINE_RESULTS[@]}" | jq -s '{phase:"baseline", results: .}' > "$BASELINE_FILE"
info "Baseline results saved to $BASELINE_FILE"

# ─── Phase 2: Concurrency Ramp ────────────────────────────────────────────────
phase "2 — Concurrency Ramp (1 → 4 → 8 → 16)"
RAMP_FILE="$RESULTS_DIR/phase2_ramp.json"
RAMP_RESULTS=()
RAMP_PROMPT="Explain what KV-cache is in LLM inference in 50 words."

for concurrency in 1 4 8 16; do
  info "Concurrency=$concurrency: sending 16 requests..."
  result=$(run_concurrent "$concurrency" 16 "$RAMP_PROMPT" 80)
  echo "$result" | jq --arg c "$concurrency" '. + {concurrency: ($c | tonumber)}'
  RAMP_RESULTS+=("$(echo "$result" | jq --arg c "$concurrency" '. + {concurrency: ($c | tonumber)}')")
done

printf '%s\n' "${RAMP_RESULTS[@]}" | jq -s '{phase: "ramp", results: .}' > "$RAMP_FILE"
info "Ramp results saved to $RAMP_FILE"

# ─── Phase 3: Sustained Load ──────────────────────────────────────────────────
phase "3 — Sustained Load (concurrency=8, 120 seconds)"
info "Running 8 concurrent clients for ~120s..."
SUSTAINED_FILE="$RESULTS_DIR/phase3_sustained.json"
SUSTAINED_PROMPT="Describe the difference between tensor parallelism and pipeline parallelism."

# Calculate ~how many requests complete in 120s assuming ~3s per request at concurrency 8
SUSTAINED_N=32
result=$(run_concurrent 8 "$SUSTAINED_N" "$SUSTAINED_PROMPT" 150)
echo "$result" | jq --arg phase "sustained" '. + {phase: $phase}' > "$SUSTAINED_FILE"
info "Sustained load results saved to $SUSTAINED_FILE"

# ─── Phase 4: Prefix Caching ──────────────────────────────────────────────────
phase "4 — Prefix Caching (shared system prompt)"
info "Testing KV-cache prefix caching..."
CACHE_FILE="$RESULTS_DIR/phase4_prefix_cache.json"

SYSTEM_PROMPT="You are an expert in AI inference engineering. You know everything about vLLM, KV-cache management, tensor parallelism, and GPU memory optimization. Always answer concisely and technically."

# Cold: first request — prompt gets prefilled from scratch
info "  Cold request (no cache hit expected)..."
COLD=$(timed_request "${SYSTEM_PROMPT} What is PagedAttention?" 80 "true")
echo "  Cold: $COLD"

# Warm: same prefix — should hit prefix cache, TTFT drops significantly
info "  Warm requests (should hit prefix cache)..."
WARM_RESULTS=()
for i in $(seq 1 5); do
  r=$(timed_request "${SYSTEM_PROMPT} What is chunked prefill?" 80 "true")
  WARM_RESULTS+=("$r")
  echo "  Warm $i: $(echo "$r" | jq -r '"TTFT=\(.ttft_s)s"')"
done

echo "{\"cold\": $COLD, \"warm\": $(printf '%s\n' "${WARM_RESULTS[@]}" | jq -s '.')}" > "$CACHE_FILE"
info "Prefix caching results saved to $CACHE_FILE"

# ─── Phase 5: KV-Cache Pressure ───────────────────────────────────────────────
phase "5 — KV-Cache Pressure (long-context requests + HPA observation)"
info "Sending long-context requests to fill KV-cache..."
PRESSURE_FILE="$RESULTS_DIR/phase5_kv_pressure.json"

# Long prompt to consume significant KV-cache slots
LONG_PROMPT="$(python3 -c "print('Please analyse the following sequence carefully: ' + ' '.join([f'item_{i}=value_{i}' for i in range(500)]))")"

info "Checking KV-cache state before pressure test..."
BEFORE_CACHE=$(curl -s "$ENDPOINT/debug/replicas" 2>/dev/null || echo "{}")
echo "Before: $(echo "$BEFORE_CACHE" | python3 -c "import sys,json; d=json.load(sys.stdin); print({k: round(v['kv_cache_usage'], 3) for k,v in d.items()})" 2>/dev/null || echo "n/a")"

info "Sending 8 long-context requests concurrently..."
result=$(run_concurrent 8 8 "$LONG_PROMPT" 200)
echo "$result"

info "Checking KV-cache state after pressure test..."
AFTER_CACHE=$(curl -s "$ENDPOINT/debug/replicas" 2>/dev/null || echo "{}")
echo "After: $(echo "$AFTER_CACHE" | python3 -c "import sys,json; d=json.load(sys.stdin); print({k: round(v['kv_cache_usage'], 3) for k,v in d.items()})" 2>/dev/null || echo "n/a")"

info "Checking HPA status (may have triggered scale-out)..."
kubectl get hpa vllm-hpa -n llm-serving 2>/dev/null || true

echo "{\"before_cache\": $BEFORE_CACHE, \"after_cache\": $AFTER_CACHE, \"load_result\": $result}" > "$PRESSURE_FILE"

# ─── Final Summary ────────────────────────────────────────────────────────────
phase "Summary"
echo ""
python3 - "$RESULTS_DIR" <<'PYEOF'
import json, os, sys

results_dir = sys.argv[1]
phases = {}
for fname in os.listdir(results_dir):
    if fname.endswith(".json"):
        with open(os.path.join(results_dir, fname)) as f:
            try:
                phases[fname] = json.load(f)
            except Exception:
                pass

print(f"\n{'Phase':<30} {'Req/s':<10} {'tok/s':<10} {'p50 lat':<10} {'p99 lat':<10} {'Errors'}")
print("-" * 75)

for name, data in sorted(phases.items()):
    if "results" in data:
        for r in data["results"]:
            if isinstance(r, dict) and "req_per_sec" in r:
                conc = r.get("concurrency", "-")
                label = f"{name} (c={conc})"[:29]
                print(f"{label:<30} {str(r.get('req_per_sec','-')):<10} "
                      f"{str(r.get('tokens_per_sec','-')):<10} "
                      f"{str(r.get('latency_p50_s','-')):<10} "
                      f"{str(r.get('latency_p99_s','-')):<10} "
                      f"{r.get('failed',0)}")
PYEOF

echo ""
info "All results saved to $RESULTS_DIR/"
info "Load test complete."

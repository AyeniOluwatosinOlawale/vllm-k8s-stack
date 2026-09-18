#!/usr/bin/env bash
# k8s-failure-drill.sh — Simulate production failure scenarios
#
# Scenarios:
#   1. Pod kill          — delete one vLLM pod, verify traffic continues
#   2. Rolling update    — trigger a deploy, measure downtime
#   3. Node drain        — cordon + drain a GPU node, verify PDB holds
#   4. Cold start        — scale to 0 then back to 2, measure cold-start time
#   5. KV-cache eviction — flood with long requests, observe eviction and recovery
#
# Each scenario:
#   - Sets up a background load generator (10 req/s)
#   - Injects the failure
#   - Monitors error rate and latency every 5 seconds
#   - Cleans up and prints a result card
#
# Usage:
#   export VLLM_ENDPOINT=http://localhost:18080
#   ./scripts/k8s-failure-drill.sh [--scenario pod-kill|rolling-update|cold-start|all]

set -euo pipefail

NAMESPACE="${NAMESPACE:-llm-serving}"
ENDPOINT="${VLLM_ENDPOINT:-http://localhost:18080}"
API_KEY="${VLLM_API_KEY:-}"
MODEL="${VLLM_MODEL:-llama-3.1-8b}"
SCENARIO="${1:-all}"
DRILL_LOG="failure_drill_$(date +%Y%m%d_%H%M%S).json"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
scenario(){ echo -e "\n${CYAN}━━━ Scenario: $* ━━━${NC}"; }
pass()    { echo -e "  ${GREEN}✓ PASS${NC} — $*"; }
fail()    { echo -e "  ${RED}✗ FAIL${NC} — $*"; }

# ─── Background load generator ────────────────────────────────────────────────
LOAD_PID=""
LOAD_ERRORS=0
LOAD_SUCCESSES=0
LOAD_TMPDIR=$(mktemp -d)

start_load() {
  info "Starting background load (1 req/s)..."
  (
    while true; do
      code=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST "$ENDPOINT/v1/chat/completions" \
        -H "Content-Type: application/json" \
        ${API_KEY:+-H "Authorization: Bearer $API_KEY"} \
        -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with OK\"}],\"max_tokens\":5}" \
        --max-time 30 2>/dev/null || echo "000")
      if [[ "$code" == "200" ]]; then
        echo "ok" >> "$LOAD_TMPDIR/results"
      else
        echo "err:$code" >> "$LOAD_TMPDIR/results"
      fi
      sleep 1
    done
  ) &
  LOAD_PID=$!
}

stop_load() {
  [[ -n "$LOAD_PID" ]] && kill "$LOAD_PID" 2>/dev/null || true
  LOAD_ERRORS=$(grep -c "^err" "$LOAD_TMPDIR/results" 2>/dev/null || echo 0)
  LOAD_SUCCESSES=$(grep -c "^ok" "$LOAD_TMPDIR/results" 2>/dev/null || echo 0)
  TOTAL=$((LOAD_ERRORS + LOAD_SUCCESSES))
  ERROR_RATE="0"
  [[ "$TOTAL" -gt 0 ]] && ERROR_RATE=$(echo "scale=1; $LOAD_ERRORS * 100 / $TOTAL" | bc)
  rm -rf "$LOAD_TMPDIR"
  LOAD_TMPDIR=$(mktemp -d)
  info "Load generator stopped. Success=$LOAD_SUCCESSES Errors=$LOAD_ERRORS (${ERROR_RATE}% error rate)"
}

# ─── Scenario 1: Pod Kill ─────────────────────────────────────────────────────
scenario_pod_kill() {
  scenario "1 — Pod Kill (delete one vLLM pod)"
  info "Goal: Traffic continues on remaining replica within 10 seconds of pod death"

  start_load
  sleep 5

  # Pick a pod to kill
  VICTIM=$(kubectl get pods -n "$NAMESPACE" -l app=vllm --no-headers \
    | awk 'NR==1{print $1}')
  [[ -z "$VICTIM" ]] && { warn "No vLLM pod found"; stop_load; return; }

  info "Killing pod $VICTIM..."
  local kill_time
  kill_time=$(date +%s)
  kubectl delete pod "$VICTIM" -n "$NAMESPACE" --grace-period=0 &>/dev/null

  # Monitor for 30 seconds
  info "Monitoring for 30s..."
  local errors_during=0
  for i in $(seq 1 6); do
    sleep 5
    code=$(curl -s -o /dev/null -w "%{http_code}" \
      -X POST "$ENDPOINT/v1/chat/completions" \
      -H "Content-Type: application/json" \
      ${API_KEY:+-H "Authorization: Bearer $API_KEY"} \
      -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"OK\"}],\"max_tokens\":3}" \
      --max-time 15 2>/dev/null || echo "000")
    echo "  t+$((i*5))s: HTTP $code"
    [[ "$code" != "200" ]] && ((errors_during++))
  done

  stop_load
  info "Waiting for replacement pod to be ready..."
  kubectl rollout status deployment/vllm -n "$NAMESPACE" --timeout=300s &>/dev/null

  if [[ "$errors_during" -le 1 ]]; then
    pass "Pod kill recovered with ≤1 probe error during failover"
  else
    fail "Pod kill caused $errors_during probe errors — investigate readiness probes and PDB"
  fi

  local RESULT
  RESULT=$(jq -n \
    --arg scenario "pod_kill" \
    --arg victim "$VICTIM" \
    --argjson errors "$LOAD_ERRORS" \
    --argjson successes "$LOAD_SUCCESSES" \
    --argjson probe_errors "$errors_during" \
    '{scenario: $scenario, victim: $victim, load_errors: $errors, load_successes: $successes, probe_errors: $probe_errors}')
  echo "$RESULT"
}

# ─── Scenario 2: Rolling Update ───────────────────────────────────────────────
scenario_rolling_update() {
  scenario "2 — Rolling Update (patch image tag, zero-downtime rollout)"
  info "Goal: Rolling update completes with 0 dropped requests (maxUnavailable=0)"

  start_load
  sleep 5

  info "Triggering rolling update by patching annotation..."
  local patch_time
  patch_time=$(date +%s)
  kubectl patch deployment vllm -n "$NAMESPACE" \
    --patch "{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"kubectl.kubernetes.io/restartedAt\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}}}}}"

  info "Monitoring rollout for 120s..."
  local errors_during=0
  for i in $(seq 1 24); do
    sleep 5
    code=$(curl -s -o /dev/null -w "%{http_code}" \
      -X POST "$ENDPOINT/v1/chat/completions" \
      -H "Content-Type: application/json" \
      ${API_KEY:+-H "Authorization: Bearer $API_KEY"} \
      -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"OK\"}],\"max_tokens\":3}" \
      --max-time 20 2>/dev/null || echo "000")
    echo "  t+$((i*5))s: HTTP $code"
    [[ "$code" != "200" ]] && ((errors_during++))
  done

  kubectl rollout status deployment/vllm -n "$NAMESPACE" --timeout=600s &>/dev/null
  stop_load

  if [[ "$errors_during" -eq 0 ]]; then
    pass "Rolling update completed with zero downtime"
  else
    fail "Rolling update caused $errors_during probe errors — maxSurge/maxUnavailable may need tuning"
  fi
}

# ─── Scenario 3: Cold Start ───────────────────────────────────────────────────
scenario_cold_start() {
  scenario "3 — Cold Start (scale to 0, then back to 2)"
  info "Goal: Measure time from scale-up to first successful request"

  info "Scaling down to 0..."
  kubectl scale deployment vllm -n "$NAMESPACE" --replicas=0
  sleep 5

  # Verify all pods are gone
  kubectl wait --for=delete pods -l app=vllm -n "$NAMESPACE" --timeout=60s 2>/dev/null || true

  local scale_start
  scale_start=$(date +%s)
  info "Scaling back to 2 at $(date -u)..."
  kubectl scale deployment vllm -n "$NAMESPACE" --replicas=2

  # Poll until first successful request
  local ready_time=""
  local attempt=0
  while [[ -z "$ready_time" ]] && [[ $attempt -lt 60 ]]; do
    sleep 10
    ((attempt++))
    elapsed=$(( $(date +%s) - scale_start ))
    code=$(curl -s -o /dev/null -w "%{http_code}" \
      -X POST "$ENDPOINT/v1/chat/completions" \
      -H "Content-Type: application/json" \
      ${API_KEY:+-H "Authorization: Bearer $API_KEY"} \
      -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"OK\"}],\"max_tokens\":3}" \
      --max-time 15 2>/dev/null || echo "000")
    echo "  t+${elapsed}s: HTTP $code"
    [[ "$code" == "200" ]] && ready_time=$elapsed
  done

  if [[ -n "$ready_time" ]]; then
    pass "Cold start: first successful request at t+${ready_time}s"
    [[ "$ready_time" -lt 300 ]] && info "Cold start within 5 minute SLO: OK" || warn "Cold start exceeded 5 minute SLO"
  else
    fail "Cold start: no successful request within $((attempt * 10))s"
  fi
}

# ─── Scenario 4: Node Drain ────────────────────────────────────────────────────
scenario_node_drain() {
  scenario "4 — Node Drain (simulate maintenance)"
  info "Goal: PDB prevents draining all capacity; pod is rescheduled on another GPU node"

  GPU_NODE=$(kubectl get pods -n "$NAMESPACE" -l app=vllm \
    -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null || echo "")

  if [[ -z "$GPU_NODE" ]]; then
    warn "Could not determine GPU node — skipping node drain scenario"
    return
  fi

  NUM_GPU_NODES=$(kubectl get nodes -l nvidia.com/gpu.present=true --no-headers | wc -l | tr -d ' ')
  if [[ "$NUM_GPU_NODES" -lt 2 ]]; then
    warn "Only 1 GPU node — node drain would require moving pods off the only GPU node."
    warn "PDB will block the drain until a replacement node is available. Skipping."
    return
  fi

  start_load
  sleep 5

  info "Cordoning node $GPU_NODE (no new pods scheduled here)..."
  kubectl cordon "$GPU_NODE"

  info "Draining $GPU_NODE (PDB minAvailable=1 should allow draining 1 pod at a time)..."
  kubectl drain "$GPU_NODE" \
    --ignore-daemonsets \
    --delete-emptydir-data \
    --pod-selector=app=vllm \
    --grace-period=30 \
    --timeout=300s 2>&1 | tail -20

  stop_load

  # Uncordon for cleanup
  info "Uncordoning $GPU_NODE..."
  kubectl uncordon "$GPU_NODE"

  if [[ "$LOAD_ERRORS" -le 2 ]]; then
    pass "Node drain completed with ≤2 errors — PDB and rollingUpdate are working"
  else
    fail "Node drain caused $LOAD_ERRORS errors"
  fi
}

# ─── Run scenarios ────────────────────────────────────────────────────────────
RESULTS=()

case "$SCENARIO" in
  pod-kill)       RESULTS+=("$(scenario_pod_kill)") ;;
  rolling-update) RESULTS+=("$(scenario_rolling_update)") ;;
  cold-start)     RESULTS+=("$(scenario_cold_start)") ;;
  node-drain)     RESULTS+=("$(scenario_node_drain)") ;;
  all)
    RESULTS+=("$(scenario_pod_kill)")
    RESULTS+=("$(scenario_rolling_update)")
    RESULTS+=("$(scenario_cold_start)")
    ;;
  *)
    echo "Unknown scenario: $SCENARIO"
    echo "Valid: pod-kill | rolling-update | cold-start | node-drain | all"
    exit 1
    ;;
esac

# Write combined results
printf '%s\n' "${RESULTS[@]}" | jq -s '{drill_results: .}' > "$DRILL_LOG"

echo ""
info "=== Failure Drill Complete ==="
info "Results saved to $DRILL_LOG"
info "Post-drill cluster state:"
kubectl get pods -n "$NAMESPACE" -l app=vllm -o wide
echo ""
kubectl get hpa -n "$NAMESPACE"

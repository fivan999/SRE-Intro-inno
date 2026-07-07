#!/usr/bin/env bash
# Lab 8 Bonus — before/after combined failure with DB pool fix
set -euo pipefail

export PATH="${HOME}/.local/bin:/opt/homebrew/bin:${PATH}"
export DOCKER_HOST="${DOCKER_HOST:-unix:///var/run/docker.sock}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${OUT:-/tmp/lab8-bonus-proofs.txt}"

prom_query() {
  local q=$1
  kubectl exec -n monitoring deployment/prometheus -- wget -qO- \
    "http://localhost:9090/api/v1/query?query=${q}" 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); r=d['data']['result']; print(r[0]['value'][1] if r else 'no data')"
}

run_combined() {
  local label=$1 db_conns=$2
  echo ""
  echo "=== $label (DB_MAX_CONNS=$db_conns) ==="
  kubectl set env deployment/payments PAYMENT_FAILURE_RATE=0.3 PAYMENT_LATENCY_MS=500
  kubectl set env deployment/events DB_MAX_CONNS="$db_conns"
  kubectl scale deployment/mixedload --replicas=3
  kubectl rollout status deployment/payments --timeout=60s
  kubectl rollout status deployment/events --timeout=120s
  sleep 180
  echo "error_rate=$(prom_query 'sum(rate(gateway_requests_total%7Bstatus%3D~%225..%22%7D%5B1m%5D))/sum(rate(gateway_requests_total%5B1m%5D))')"
  echo "p99_reserve=$(prom_query 'histogram_quantile(0.99,+sum+by+(le)+(rate(gateway_request_duration_seconds_bucket%7Bpath%3D%22%2Fevents%2F%7Bid%7D%2Freserve%22%7D%5B1m%5D)))')"
  echo "p99_pay=$(prom_query 'histogram_quantile(0.99,+sum+by+(le)+(rate(gateway_request_duration_seconds_bucket%7Bpath%3D%22%2Freserve%2F%7Bid%7D%2Fpay%22%7D%5B1m%5D)))')"
  echo "db_pool_used=$(prom_query 'events_db_pool_size')"
}

restore() {
  kubectl set env deployment/payments PAYMENT_FAILURE_RATE=0.0 PAYMENT_LATENCY_MS=0
  kubectl apply -f "$REPO_ROOT/k8s/events.yaml"
  kubectl rollout status deployment/events --timeout=120s
  kubectl scale deployment/mixedload --replicas=2
}

{
  echo "=== Lab 8 Bonus proofs ==="
  kubectl apply -f "$REPO_ROOT/labs/lab8/mixedload.yaml" 2>/dev/null || true
  kubectl exec -i deploy/postgres -- psql -U quickticket -d quickticket < "$REPO_ROOT/app/seed.sql" >/dev/null 2>&1 || true

  echo "Weakness: events DB pool exhaustion under DB_MAX_CONNS=3 + mixed load"
  echo "Fix: k8s/events.yaml — DB_MAX_CONNS=20, higher CPU/memory requests"

  run_combined "BEFORE fix" 3

  echo ""
  echo "=== Applying fix ==="
  kubectl apply -f "$REPO_ROOT/k8s/events.yaml"
  kubectl rollout status deployment/events --timeout=120s
  sleep 30

  run_combined "AFTER fix" 20

  restore
  echo ""
  echo "=== Done ==="
} | tee "$OUT"

echo "Bonus proofs saved to $OUT"

#!/usr/bin/env bash
# Lab 8 — chaos experiments with mixedload + in-cluster Prometheus
set -euo pipefail

export PATH="${HOME}/.local/bin:/opt/homebrew/bin:${PATH}"
export DOCKER_HOST="${DOCKER_HOST:-unix:///var/run/docker.sock}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${OUT:-/tmp/lab8-proofs.txt}"

prom_query() {
  local q=$1
  kubectl exec -n monitoring deployment/prometheus -- wget -qO- \
    "http://localhost:9090/api/v1/query?query=${q}" 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); r=d['data']['result']; print(r[0]['value'][1] if r else 'no data')"
}

prom_query_json() {
  local q=$1
  kubectl exec -n monitoring deployment/prometheus -- wget -qO- \
    "http://localhost:9090/api/v1/query?query=${q}" 2>/dev/null \
    | python3 -m json.tool 2>/dev/null | head -25
}

chaos_probe() {
  kubectl run chaos-probe-$RANDOM --image=curlimages/curl:latest --rm -i --restart=Never --quiet --command -- \
    sh -c 'echo "GET /events:"; curl -s -o /dev/null -w "%{http_code} %{time_total}s\n" http://gateway:8080/events;
           echo "POST /reserve:"; curl -s -X POST -w "%{http_code} %{time_total}s\n" \
                -H "Content-Type: application/json" -d "{\"quantity\":1}" \
                http://gateway:8080/events/1/reserve;
           echo "GET /health:"; curl -s http://gateway:8080/health'
}

wait_gateway_5() {
  kubectl wait --for=condition=Ready pod -l app=gateway --timeout=120s
  local n
  n=$(kubectl get pods -l app=gateway --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')
  [ "$n" -ge 5 ]
}

seed_db() {
  kubectl exec -i deploy/postgres -- psql -U quickticket -d quickticket < "$REPO_ROOT/app/seed.sql" >/dev/null 2>&1 || true
}

{
  echo "=== Lab 8 proofs ==="
  seed_db

  echo ""
  echo "=== Setup: mixedload ==="
  kubectl apply -f "$REPO_ROOT/labs/lab8/mixedload.yaml"
  kubectl rollout status deployment/mixedload --timeout=60s
  echo "Baseline RPS (wait 90s)..."
  sleep 90
  echo "RPS=$(prom_query 'sum(rate(gateway_requests_total%5B1m%5D))')"

  echo ""
  echo "=== Experiment 1: Pod kill ==="
  echo "HYPOTHESIS: delete 1 gateway pod → brief errors, K8s replaces pod in ~30s, traffic shifts to other 4"
  VICTIM=$(kubectl get pods -l app=gateway -o name | head -1)
  T_KILL=$(date +%H:%M:%S)
  echo "Killing $VICTIM at $T_KILL"
  kubectl delete "$VICTIM" --wait=false
  sleep 5
  echo "Pods after 5s:"
  kubectl get pods -l app=gateway -o wide
  T_READY=""
  for i in $(seq 1 60); do
    n=$(kubectl get pods -l app=gateway --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [ "$n" -ge 5 ]; then T_READY=$(date +%H:%M:%S); break; fi
    sleep 2
  done
  echo "5/5 Running again at: ${T_READY:-timeout}"
  sleep 30
  echo "5xx increase (3m): $(prom_query 'sum(increase(gateway_requests_total%7Bstatus%3D~%225..%22%7D%5B3m%5D))')"
  echo "Per-pod rate:"
  prom_query_json 'sum+by+(pod)+(rate(gateway_requests_total%5B1m%5D))'

  echo ""
  echo "=== Experiment 2: Payment latency ==="
  echo "HYPOTHESIS: PAYMENT_LATENCY_MS=2000 → /pay slower but no 5xx (timeout 5000ms)"
  kubectl set env deployment/payments PAYMENT_LATENCY_MS=2000
  kubectl rollout status deployment/payments --timeout=60s
  sleep 90
  echo "Error rate @2s latency: $(prom_query 'sum(rate(gateway_requests_total%7Bstatus%3D~%225..%22%7D%5B1m%5D))/sum(rate(gateway_requests_total%5B1m%5D))')"
  echo "p99 by path @2s:"
  prom_query_json 'histogram_quantile(0.99,+sum+by+(le,path)+(rate(gateway_request_duration_seconds_bucket%5B1m%5D)))'

  echo ""
  echo "HYPOTHESIS: PAYMENT_LATENCY_MS=6000 → /pay returns 504 (gateway timeout 5000ms)"
  kubectl set env deployment/payments PAYMENT_LATENCY_MS=6000
  kubectl rollout status deployment/payments --timeout=60s
  sleep 90
  echo "Error rate @6s latency: $(prom_query 'sum(rate(gateway_requests_total%7Bstatus%3D~%225..%22%7D%5B1m%5D))/sum(rate(gateway_requests_total%5B1m%5D))')"
  echo "p99 by path @6s:"
  prom_query_json 'histogram_quantile(0.99,+sum+by+(le,path)+(rate(gateway_request_duration_seconds_bucket%5B1m%5D)))'

  kubectl set env deployment/payments PAYMENT_LATENCY_MS=0
  kubectl rollout status deployment/payments --timeout=60s
  sleep 60

  echo ""
  echo "=== Experiment 3: Redis down ==="
  echo "HYPOTHESIS: Redis down → /events OK, /reserve fails, health degraded"
  kubectl scale deployment/redis --replicas=0
  kubectl wait --for=delete pod -l app=redis --timeout=60s 2>/dev/null || sleep 10
  echo "Probe with Redis down:"
  chaos_probe
  kubectl scale deployment/redis --replicas=1
  kubectl wait --for=condition=Available deployment/redis --timeout=60s
  sleep 30
  echo "Probe after restore:"
  chaos_probe

  echo ""
  echo "=== Task 2: Combined failure ==="
  kubectl set env deployment/payments PAYMENT_FAILURE_RATE=0.3 PAYMENT_LATENCY_MS=500
  kubectl set env deployment/events DB_MAX_CONNS=3
  kubectl scale deployment/mixedload --replicas=3
  kubectl rollout status deployment/payments --timeout=60s
  kubectl rollout status deployment/events --timeout=60s
  sleep 180
  echo "Combined error rate: $(prom_query 'sum(rate(gateway_requests_total%7Bstatus%3D~%225..%22%7D%5B1m%5D))/sum(rate(gateway_requests_total%5B1m%5D))')"
  echo "Combined p99:"
  prom_query_json 'histogram_quantile(0.99,+sum+by+(le,path)+(rate(gateway_request_duration_seconds_bucket%5B1m%5D)))'

  kubectl set env deployment/payments PAYMENT_FAILURE_RATE=0.0 PAYMENT_LATENCY_MS=0
  kubectl set env deployment/events DB_MAX_CONNS=10
  kubectl scale deployment/mixedload --replicas=2

} | tee "$OUT"

echo "Proofs saved to $OUT"

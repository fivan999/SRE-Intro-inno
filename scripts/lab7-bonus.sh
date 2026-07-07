#!/usr/bin/env bash
# Lab 7 Bonus — automated canary analysis with in-cluster Prometheus
set -euo pipefail

export PATH="${HOME}/.local/bin:/opt/homebrew/bin:${PATH}"
export DOCKER_HOST="${DOCKER_HOST:-unix:///var/run/docker.sock}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${OUT:-/tmp/lab7-bonus-proofs.txt}"

kubectl_rollouts() {
  if command -v kubectl-argo-rollouts >/dev/null 2>&1; then
    kubectl-argo-rollouts "$@"
  else
    kubectl argo rollouts "$@"
  fi
}

wait_healthy() {
  kubectl_rollouts status gateway --timeout=300s
}

seed_db() {
  kubectl exec -i deploy/postgres -- psql -U quickticket -d quickticket < "$REPO_ROOT/app/seed.sql" >/dev/null
  kubectl exec deploy/events -- python3 -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8081/events')" >/dev/null
}

patch_env() {
  local version=$1 events_url=${2:-http://events:8081} timeout_ms=${3:-5000}
  kubectl patch rollout gateway --type=json \
    -p="[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/env\",\"value\":[
      {\"name\":\"APP_VERSION\",\"value\":\"${version}\"},
      {\"name\":\"EVENTS_URL\",\"value\":\"${events_url}\"},
      {\"name\":\"PAYMENTS_URL\",\"value\":\"http://payments:8082\"},
      {\"name\":\"GATEWAY_TIMEOUT_MS\",\"value\":\"${timeout_ms}\"}
    ]}]"
}

{
  echo "=== Lab 7 Bonus proofs ==="

  echo ""
  echo "=== B.1 Prometheus ==="
  kubectl apply -f "$REPO_ROOT/labs/lab7/prometheus.yaml"
  kubectl -n monitoring rollout status deployment/prometheus --timeout=120s
  sleep 15
  kubectl port-forward -n monitoring svc/prometheus 9091:9090 >/tmp/prom-pf.log 2>&1 &
  PF=$!
  sleep 3
  curl -sf 'http://localhost:9091/api/v1/targets?state=active' | python3 -c "
import sys,json
for t in json.load(sys.stdin)['data']['activeTargets']:
    if t['labels'].get('job')=='gateway':
        print(t['labels'].get('pod'), 'rs=', t['labels'].get('rs_hash'), t['health'])
"
  kill $PF 2>/dev/null || true

  echo ""
  echo "=== B.2 AnalysisTemplate ==="
  kubectl apply -f "$REPO_ROOT/k8s/analysis-template.yaml"
  kubectl get analysistemplate gateway-error-rate

  echo ""
  echo "=== B.3 Rollout with analysis strategy ==="
  seed_db
  kubectl apply -f "$REPO_ROOT/k8s/gateway.yaml"
  kubectl_rollouts abort rollout gateway 2>/dev/null || true
  kubectl_rollouts retry rollout gateway 2>/dev/null || true
  wait_healthy
  kubectl_rollouts get rollout gateway

  echo ""
  echo "=== B.4 Good version auto-promote ==="
  kubectl apply -f "$REPO_ROOT/labs/lab7/loadgen.yaml"
  echo "Warming loadgen (90s)..."
  sleep 90
  patch_env v4-good
  echo "Waiting for analysis + auto-promote (up to 5 min)..."
  kubectl_rollouts status gateway --timeout=360s
  kubectl_rollouts get rollout gateway
  echo ""
  echo "--- AnalysisRuns (good) ---"
  kubectl get analysisrun

  echo ""
  echo "=== B.5 Bad version auto-abort ==="
  wait_healthy
  # 1ms client timeout: /health still passes (uses 2s), /events returns 504.
  patch_env v5-bad "http://events:8081" 1
  echo "Waiting for analysis failure + auto-abort (up to 5 min)..."
  for i in $(seq 1 60); do
    phase=$(kubectl get rollout gateway -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    if [ "$phase" = "Degraded" ]; then break; fi
    sleep 5
  done
  kubectl_rollouts get rollout gateway
  echo ""
  echo "--- AnalysisRuns (all) ---"
  kubectl get analysisrun
  FAILED=$(kubectl get analysisrun -o json | python3 -c "
import sys,json
runs=json.load(sys.stdin)['items']
failed=[r['metadata']['name'] for r in runs if r.get('status',{}).get('phase')=='Failed']
print(failed[-1] if failed else '')
")
  if [ -n "$FAILED" ]; then
    echo ""
    echo "=== Failed AnalysisRun measurements ==="
    kubectl get analysisrun "$FAILED" -o yaml | grep -A30 'status:'
  fi

  echo ""
  echo "=== B.6 Revert EVENTS_URL + cleanup ==="
  kubectl apply -f "$REPO_ROOT/k8s/gateway.yaml"
  kubectl_rollouts retry rollout gateway 2>/dev/null || true
  wait_healthy || true
  kubectl delete -f "$REPO_ROOT/labs/lab7/loadgen.yaml" --ignore-not-found
  kubectl_rollouts get rollout gateway
} | tee "$OUT"

echo "Bonus proofs saved to $OUT"

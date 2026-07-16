#!/usr/bin/env bash
# Lab 11 — notifications + retry/CB/rate-limit/bulkhead proofs
set -euo pipefail

export PATH="${HOME}/.local/bin:/opt/homebrew/bin:${PATH}"
export DOCKER_HOST="${DOCKER_HOST:-unix:///var/run/docker.sock}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${OUT:-/tmp/lab11-proofs.txt}"
ARCH="$(uname -m)"
case "$ARCH" in
  arm64|aarch64) ROLLOUTS_ARCH=darwin-arm64 ;;
  *) ROLLOUTS_ARCH=linux-amd64 ;;
esac
cd "$REPO_ROOT"

prom_query() {
  kubectl exec -n monitoring deployment/prometheus -- wget -qO- \
    "http://localhost:9090/api/v1/query?query=$1" 2>/dev/null \
    | python3 -c "
import sys, json
r = json.load(sys.stdin)['data']['result']
if not r:
    print('no data')
else:
    for item in r:
        labels = item.get('metric', {})
        val = item['value'][1]
        if labels:
            parts = ','.join(f'{k}=\"{v}\"' for k, v in sorted(labels.items()) if k != '__name__')
            print(f'{parts} {val}')
        else:
            print(val)
"
}

checkout_burst() {
  kubectl run "$1" --image=curlimages/curl:latest --rm -i --restart=Never --quiet --command -- sh -c '
ok=0; fail=0
for i in $(seq 1 30); do
  RES=$(curl -s -X POST http://gateway:8080/events/3/reserve -H "Content-Type: application/json" -d "{\"quantity\":1}")
  RID=$(echo "$RES" | sed -n "s/.*\"reservation_id\":\"\\([^\"]*\\).*/\\1/p")
  if [ -z "$RID" ]; then fail=$((fail+1)); continue; fi
  CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "http://gateway:8080/reserve/$RID/pay")
  if [ "$CODE" = "200" ]; then ok=$((ok+1)); else fail=$((fail+1)); fi
  sleep 0.1
done
echo "result: ok=$ok fail=$fail"
'
}

ensure_rollouts() {
  if command -v kubectl-argo-rollouts >/dev/null 2>&1; then return; fi
  mkdir -p "${HOME}/.local/bin"
  curl -fsSL -o "${HOME}/.local/bin/kubectl-argo-rollouts" \
    "https://github.com/argoproj/argo-rollouts/releases/latest/download/kubectl-argo-rollouts-${ROLLOUTS_ARCH}"
  chmod +x "${HOME}/.local/bin/kubectl-argo-rollouts"
}

ensure_cluster() {
  podman machine start 2>/dev/null || true
  sleep 3
  export DOCKER_HOST="${DOCKER_HOST:-unix:///var/run/docker.sock}"
  if ! kubectl get nodes >/dev/null 2>&1; then
    k3d cluster delete quickticket 2>/dev/null || true
    sleep 2
    k3d cluster create quickticket \
      --k3s-arg '--kubelet-arg=feature-gates=KubeletInUserNamespace=true@server:*' \
      --timeout 600s --wait
  fi
  k3d kubeconfig merge quickticket --kubeconfig-switch-context >/dev/null 2>&1 || true
  export KUBECONFIG="${KUBECONFIG:-$(k3d kubeconfig write quickticket)}"
  kubectl wait --for=condition=Ready node --all --timeout=120s
  sleep 10
}

kubectl_ready() {
  for i in $(seq 1 60); do
    export KUBECONFIG="$(k3d kubeconfig write quickticket 2>/dev/null || true)"
    if [ -n "${KUBECONFIG:-}" ] && kubectl get nodes >/dev/null 2>&1; then
      return 0
    fi
    sleep 5
  done
  return 1
}

build_images() {
  # Build events/payments too — fresh cluster has no local images.
  docker build -t quickticket-notifications:v1 ./app/notifications
  docker build -t quickticket-gateway:v1 ./app/gateway
  docker build -t quickticket-events:v1 ./app/events
  docker build -t quickticket-payments:v1 ./app/payments
  docker save \
    quickticket-notifications:v1 \
    quickticket-gateway:v1 \
    quickticket-events:v1 \
    quickticket-payments:v1 \
    -o /tmp/quickticket-images.tar
  k3d image import -c quickticket /tmp/quickticket-images.tar
  # Image import briefly breaks API via tools node — wait + refresh kubeconfig.
  sleep 20
  kubectl_ready
}

deploy_stack() {
  kubectl_ready
  kubectl create namespace argo-rollouts 2>/dev/null || true
  kubectl apply -n argo-rollouts -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml
  kubectl wait --for=condition=Available deployment/argo-rollouts -n argo-rollouts --timeout=120s
  kubectl apply -f "$REPO_ROOT/k8s/postgres.yaml"
  kubectl apply -f "$REPO_ROOT/k8s/redis.yaml"
  kubectl apply -f "$REPO_ROOT/k8s/events.yaml"
  kubectl apply -f "$REPO_ROOT/k8s/payments.yaml"
  kubectl apply -f "$REPO_ROOT/k8s/notifications.yaml"
  kubectl delete deployment gateway --ignore-not-found 2>/dev/null || true
  kubectl apply -f "$REPO_ROOT/labs/lab7/analysis-template.yaml"
  kubectl apply -f "$REPO_ROOT/k8s/gateway.yaml"
  kubectl rollout status deployment/postgres --timeout=180s
  kubectl argo rollouts status gateway --timeout=300s 2>/dev/null \
    || kubectl-argo-rollouts status gateway --timeout=300s
  kubectl rollout status deployment/events --timeout=180s
  kubectl rollout status deployment/payments --timeout=180s
  kubectl rollout status deployment/notifications --timeout=120s
  kubectl apply -f "$REPO_ROOT/labs/lab7/prometheus.yaml"
  kubectl apply -f "$REPO_ROOT/labs/lab8/mixedload.yaml"
  kubectl rollout status deployment/mixedload --timeout=60s
  kubectl exec -i "$(kubectl get pod -l app=postgres -o name)" -- \
    psql -U quickticket -d quickticket < "$REPO_ROOT/app/seed.sql" >/dev/null 2>&1 || true
  sleep 30
}

{
  echo "=== Lab 11 proofs ==="
  ensure_rollouts
  ensure_cluster
  export KUBECONFIG="${KUBECONFIG:-$(k3d kubeconfig write quickticket)}"
  build_images
  deploy_stack

  echo ""
  echo "=== Test #1: fire-and-forget (NOTIFY_FAILURE_RATE=0.3, LATENCY=300) ==="
  kubectl set env deployment/notifications NOTIFY_FAILURE_RATE=0.3 NOTIFY_LATENCY_MS=300
  kubectl rollout status deployment/notifications --timeout=60s
  sleep 5
  checkout_burst checkout-burst-1
  echo "pay p99:"
  prom_query 'histogram_quantile(0.99,+sum+by+(le,path)+(rate(gateway_request_duration_seconds_bucket%7Bpath%3D%22%2Freserve%2F%7Bid%7D%2Fpay%22%7D%5B2m%5D)))'
  kubectl set env deployment/notifications NOTIFY_FAILURE_RATE=0.0 NOTIFY_LATENCY_MS=0
  kubectl rollout status deployment/notifications --timeout=60s

  echo ""
  echo "=== Test #2: retries (PAYMENT_FAILURE_RATE=0.3) ==="
  kubectl set env deployment/payments PAYMENT_FAILURE_RATE=0.3
  kubectl rollout status deployment/payments --timeout=60s
  sleep 5
  checkout_burst retry-test
  echo "gateway_retry_total:"
  prom_query 'sum+by+(target,result)+(gateway_retry_total)'
  kubectl set env deployment/payments PAYMENT_FAILURE_RATE=0.0
  kubectl rollout status deployment/payments --timeout=60s

  echo ""
  echo "=== notifications_notify_total ==="
  kubectl run notify-metrics --image=curlimages/curl:latest --rm -i --restart=Never --quiet \
    --command -- curl -s http://notifications:8083/metrics | grep notifications_notify_total || true

  echo ""
  echo "=== CB test (PAYMENT_FAILURE_RATE=1.0) ==="
  kubectl set env deployment/payments PAYMENT_FAILURE_RATE=1.0
  kubectl rollout status deployment/payments --timeout=60s
  sleep 5
  kubectl run cb-probe --image=curlimages/curl:latest --rm -i --restart=Never --quiet --command -- sh -c '
STATS_500=0; STATS_503=0
for i in $(seq 1 80); do
  RES=$(curl -s -X POST http://gateway:8080/events/3/reserve -H "Content-Type: application/json" -d "{\"quantity\":1}")
  RID=$(echo "$RES" | sed -n "s/.*\"reservation_id\":\"\\([^\"]*\\).*/\\1/p")
  [ -z "$RID" ] && continue
  CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "http://gateway:8080/reserve/$RID/pay")
  case "$CODE" in
    500) STATS_500=$((STATS_500+1));;
    503) STATS_503=$((STATS_503+1));;
  esac
done
echo "500s=$STATS_500 503s=$STATS_503"
'
  kubectl set env deployment/payments PAYMENT_FAILURE_RATE=0.0
  kubectl rollout status deployment/payments --timeout=60s
  sleep 35
  echo "=== CB recovery ==="
  kubectl run cb-probe2 --image=curlimages/curl:latest --rm -i --restart=Never --quiet --command -- sh -c '
for i in $(seq 1 15); do
  RES=$(curl -s -X POST http://gateway:8080/events/3/reserve -H "Content-Type: application/json" -d "{\"quantity\":1}")
  RID=$(echo "$RES" | sed -n "s/.*\"reservation_id\":\"\\([^\"]*\\).*/\\1/p")
  [ -z "$RID" ] && continue
  CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "http://gateway:8080/reserve/$RID/pay")
  echo "[$i] $CODE"
done
'
  echo "CB transitions:"
  prom_query 'sum+by+(to)+(gateway_circuit_breaker_transitions_total)'

  echo ""
  echo "=== Rate limit burst ==="
  kubectl run rl-burst --image=curlimages/curl:latest --rm -i --restart=Never --quiet --command -- sh -c '
OK=0; LIMITED=0
for i in $(seq 1 100); do
  CODE=$(curl -s -o /dev/null -w "%{http_code}" http://gateway:8080/events)
  case "$CODE" in
    200) OK=$((OK+1));;
    429) LIMITED=$((LIMITED+1));;
  esac
done
echo "200=$OK 429=$LIMITED"
'
  echo "Retry-After header:"
  kubectl run rl-headers --image=curlimages/curl:latest --rm -i --restart=Never --quiet --command -- sh -c '
for i in $(seq 1 50); do curl -s -o /dev/null http://gateway:8080/events; done
curl -s -D - -o /dev/null http://gateway:8080/events | grep -iE "^(HTTP|retry-after)"
'
  echo "rate_limit_rejections:"
  prom_query 'sum+by+(path)+(gateway_rate_limit_rejections_total)'

  echo ""
  echo "=== Bonus: bulkhead (1 gateway replica, MAX=3, LATENCY=3000) ==="
  kubectl patch rollout gateway --type=merge -p '{"spec":{"replicas":1}}'
  # JSON-patch env value for BULKHEAD_PAYMENTS_MAX (Rollout rejects strategic merge)
  ENV_IDX=$(kubectl get rollout gateway -o json | python3 -c '
import json,sys
envs=json.load(sys.stdin)["spec"]["template"]["spec"]["containers"][0].get("env",[])
print(next((i for i,e in enumerate(envs) if e.get("name")=="BULKHEAD_PAYMENTS_MAX"), -1))
')
  if [ "$ENV_IDX" = "-1" ]; then
    kubectl patch rollout gateway --type=json \
      -p='[{"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{"name":"BULKHEAD_PAYMENTS_MAX","value":"3"}}]'
  else
    kubectl patch rollout gateway --type=json \
      -p="[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/env/${ENV_IDX}/value\",\"value\":\"3\"}]"
  fi
  kubectl argo rollouts status gateway --timeout=240s 2>/dev/null \
    || kubectl-argo-rollouts status gateway --timeout=240s
  kubectl set env deployment/payments PAYMENT_LATENCY_MS=3000 PAYMENT_FAILURE_RATE=0.0
  kubectl rollout status deployment/payments --timeout=60s
  sleep 8
  kubectl run bulkhead-probe --image=curlimages/curl:latest --rm -i --restart=Never --quiet --command -- sh -c '
for i in $(seq 1 30); do
  (
    RES=$(curl -s -X POST http://gateway:8080/events/3/reserve -H "Content-Type: application/json" -d "{\"quantity\":1}")
    RID=$(echo "$RES" | sed -n "s/.*\"reservation_id\":\"\\([^\"]*\\).*/\\1/p")
    [ -z "$RID" ] && exit
    CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "http://gateway:8080/reserve/$RID/pay")
    echo "pay[$i] $CODE"
  ) &
done
EV_SLOW=0; EV_OK=0
for j in $(seq 1 30); do
  T=$(curl -s -o /dev/null -w "%{time_total}" http://gateway:8080/events)
  awk -v t="$T" "BEGIN{ if (t > 0.5) exit 1 }" && EV_OK=$((EV_OK+1)) || EV_SLOW=$((EV_SLOW+1))
  sleep 0.1
done
wait
echo "EVENTS: ok=$EV_OK slow=$EV_SLOW"
'
  echo "bulkhead_rejections:"
  prom_query 'sum+by+(target)+(gateway_bulkhead_rejections_total)'
  echo "bulkhead_in_flight max:"
  prom_query 'max_over_time(gateway_bulkhead_in_flight%7Btarget%3D%22payments%22%7D%5B2m%5D)'
  kubectl set env deployment/payments PAYMENT_LATENCY_MS=0
  kubectl patch rollout gateway --type=merge -p '{"spec":{"replicas":5}}'
  kubectl argo rollouts status gateway --timeout=300s 2>/dev/null \
    || kubectl-argo-rollouts status gateway --timeout=300s

} | tee "$OUT"

echo "Proofs saved to $OUT"

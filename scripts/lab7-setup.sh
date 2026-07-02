#!/usr/bin/env bash
# Lab 7 — Argo Rollouts canary: install, deploy, promote, abort, capture proofs
set -euo pipefail

export PATH="${HOME}/.local/bin:/opt/homebrew/bin:${PATH}"
export DOCKER_HOST="${DOCKER_HOST:-unix:///var/run/docker.sock}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${OUT:-/tmp/lab7-proofs.txt}"
ARCH="$(uname -m)"
case "$ARCH" in
  arm64|aarch64) ROLLOUTS_ARCH=darwin-arm64 ;;
  *) ROLLOUTS_ARCH=linux-amd64 ;;
esac

kubectl_rollouts() {
  if command -v kubectl-argo-rollouts >/dev/null 2>&1; then
    kubectl-argo-rollouts "$@"
  else
    kubectl argo rollouts "$@"
  fi
}

wait_nodes() {
  kubectl wait --for=condition=Ready node --all --timeout=180s
}

ensure_rollouts_plugin() {
  if command -v kubectl-argo-rollouts >/dev/null 2>&1; then return; fi
  mkdir -p "${HOME}/.local/bin"
  curl -fsSL -o "${HOME}/.local/bin/kubectl-argo-rollouts" \
    "https://github.com/argoproj/argo-rollouts/releases/latest/download/kubectl-argo-rollouts-${ROLLOUTS_ARCH}"
  chmod +x "${HOME}/.local/bin/kubectl-argo-rollouts"
}

ensure_cluster() {
  if kubectl get nodes >/dev/null 2>&1; then
    wait_nodes
    return
  fi
  echo "Cluster unreachable — create with:"
  echo "  k3d cluster create quickticket --k3s-arg '--kubelet-arg=feature-gates=KubeletInUserNamespace=true@server:*'"
  exit 1
}

ensure_ghcr_secret() {
  if kubectl get secret ghcr-secret >/dev/null 2>&1; then return; fi
  if ! command -v gh >/dev/null 2>&1; then
    echo "gh CLI required to create ghcr-secret"
    exit 1
  fi
  kubectl create secret docker-registry ghcr-secret \
    --docker-server=ghcr.io \
    --docker-username=fivan999 \
    --docker-password="$(gh auth token)"
}

install_rollouts() {
  kubectl create namespace argo-rollouts 2>/dev/null || true
  kubectl apply -n argo-rollouts -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml
  kubectl wait --for=condition=Available deployment/argo-rollouts -n argo-rollouts --timeout=120s
}

apply_stack() {
  kubectl apply -f "$REPO_ROOT/k8s/postgres.yaml"
  kubectl apply -f "$REPO_ROOT/k8s/redis.yaml"
  kubectl apply -f "$REPO_ROOT/k8s/events.yaml"
  kubectl apply -f "$REPO_ROOT/k8s/payments.yaml"
  kubectl delete deployment gateway --ignore-not-found
  kubectl apply -f "$REPO_ROOT/k8s/gateway.yaml"
  kubectl rollout status deployment/events --timeout=180s
  kubectl rollout status deployment/payments --timeout=180s
  kubectl argo rollouts status gateway --timeout=300s 2>/dev/null || kubectl_rollouts status gateway --timeout=300s
}

wait_paused() {
  local i
  for i in $(seq 1 60); do
    if kubectl_rollouts get rollout gateway 2>/dev/null | grep -q 'Paused'; then
      return 0
    fi
    sleep 2
  done
  return 1
}

{
  echo "=== Lab 7 proofs ==="
  ensure_rollouts_plugin
  ensure_cluster
  ensure_ghcr_secret
  install_rollouts

  echo ""
  echo "=== 7.1 rollouts version ==="
  kubectl_rollouts version

  apply_stack

  echo ""
  echo "=== 7.3 trigger canary (APP_VERSION=v3) ==="
  kubectl patch rollout gateway --type=json -p='[{"op":"replace","path":"/spec/template/spec/containers/0/env/0/value","value":"v3"}]' \
    || kubectl set env rollout/gateway APP_VERSION=v3
  wait_paused || true
  echo ""
  echo "=== 7.3 Paused at 20% ==="
  kubectl_rollouts get rollout gateway

  echo ""
  echo "=== 7.4 traffic split (loadgen 30s) ==="
  kubectl apply -f "$REPO_ROOT/labs/lab7/loadgen.yaml"
  sleep 30
  for pod in $(kubectl get pods -l app=gateway -o name); do
    count=$(kubectl logs "$pod" 2>/dev/null | grep -c 'GET /events' || echo 0)
    img=$(kubectl get "$pod" -o jsonpath='{.spec.containers[0].image}')
    ver=$(kubectl get "$pod" -o jsonpath='{.spec.containers[0].env[?(@.name=="APP_VERSION")].value}')
    echo "$pod image=$img APP_VERSION=$ver events_requests=$count"
  done

  echo ""
  echo "=== 7.5 promote to 100% ==="
  kubectl_rollouts promote gateway
  kubectl_rollouts status gateway --timeout=300s
  kubectl_rollouts get rollout gateway

  echo ""
  echo "=== 7.6 bad canary + abort ==="
  T_ABORT_START=$(date +%s)
  kubectl patch rollout gateway --type=json -p='[{"op":"replace","path":"/spec/template/spec/containers/0/env/0/value","value":"v3-bad"}]'
  wait_paused || true
  echo "--- paused bad canary ---"
  kubectl_rollouts get rollout gateway
  kubectl_rollouts abort gateway
  T_ABORT_END=$(date +%s)
  echo "abort_command_seconds=$((T_ABORT_END - T_ABORT_START))"
  sleep 3
  kubectl_rollouts get rollout gateway

  kubectl delete -f "$REPO_ROOT/labs/lab7/loadgen.yaml" --ignore-not-found
} | tee "$OUT"

echo "Proofs saved to $OUT"

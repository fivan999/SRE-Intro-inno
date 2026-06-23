#!/usr/bin/env bash
# Lab 5 full run: fix Podman cpuset → k3d → ArgoCD → verify → task2
set -euo pipefail

PODMAN="${PODMAN:-/opt/homebrew/bin/podman}"
export DOCKER_HOST=unix:///var/run/docker.sock
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
BRANCH="${LAB_BRANCH:-feature/lab5}"
ARGOCD=/tmp/argocd
VERIFY_LOG=/tmp/lab5-verify.log
TASK2_LOG=/tmp/lab5-task2.log

ensure_podman() {
  "$PODMAN" machine start 2>/dev/null || true
  for _ in $(seq 1 30); do
    "$PODMAN" ps >/dev/null 2>&1 && return 0
    "$PODMAN" machine stop 2>/dev/null || true
    sleep 2
    "$PODMAN" machine start
    sleep 5
  done
  echo "Podman unavailable"; exit 1
}

fix_cpuset() {
  "$PODMAN" machine ssh bash -e <<'EOF'
sudo mkdir -p /etc/systemd/system/user@.service.d
printf '[Service]\nDelegate=cpu cpuset io memory pids\n' | sudo tee /etc/systemd/system/user@.service.d/delegate.conf
sudo systemctl daemon-reload
EOF
}

ensure_k3d() {
  if kubectl get nodes 2>/dev/null | grep -q Ready; then return 0; fi
  k3d cluster delete quickticket 2>/dev/null || true
  k3d cluster create quickticket \
    --k3s-arg '--kubelet-arg=feature-gates=KubeletInUserNamespace=true@server:*' \
    --timeout 300s --wait
  kubectl get nodes
}

argocd_login() {
  [ -x "$ARGOCD" ] || (curl -sSL -o "$ARGOCD" https://github.com/argoproj/argo-cd/releases/latest/download/argocd-darwin-arm64 && chmod +x "$ARGOCD")
  pkill -f 'port-forward svc/argocd-server' 2>/dev/null || true
  kubectl port-forward svc/argocd-server -n argocd 8443:443 >/tmp/argocd-pf.log 2>&1 &
  PF=$!
  for i in $(seq 1 30); do curl -sfk https://localhost:8443 >/dev/null 2>&1 && break; sleep 1; done
  PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)
  "$ARGOCD" login localhost:8443 --insecure --username admin --password "$PASS"
  echo "$PF"
}

setup_argocd() {
  kubectl delete secret ghcr-secret 2>/dev/null || true
  kubectl create secret docker-registry ghcr-secret \
    --docker-server=ghcr.io \
    --docker-username=fivan999 \
    --docker-password="$(gh auth token)"

  kubectl create namespace argocd 2>/dev/null || true
  kubectl apply -n argocd --server-side --force-conflicts \
    -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
  kubectl wait --for=condition=Available deployment/argocd-server -n argocd --timeout=180s

  PF=$(argocd_login)
  if ! kubectl get application quickticket -n argocd >/dev/null 2>&1; then
    "$ARGOCD" app create quickticket \
      --repo https://github.com/fivan999/SRE-Intro-inno.git \
      --path k8s \
      --revision "$BRANCH" \
      --dest-server https://kubernetes.default.svc \
      --dest-namespace default \
      --sync-policy automated
  else
    "$ARGOCD" app set quickticket --revision "$BRANCH" 2>/dev/null || true
  fi
  "$ARGOCD" app sync quickticket
  for d in postgres redis gateway events payments; do
    kubectl wait --for=condition=available "deployment/$d" -n default --timeout=300s
  done
  "$ARGOCD" app wait quickticket --sync --health --timeout 300
  PGPOD=$(kubectl get pod -l app=postgres -n default -o jsonpath='{.items[0].metadata.name}')
  kubectl exec -i "$PGPOD" -- psql -U quickticket -d quickticket < app/seed.sql | tail -2

  {
    echo "=== argocd app get quickticket ==="
    "$ARGOCD" app get quickticket
    echo "=== kubectl get pods ==="
    kubectl get pods -n default
    echo "=== gateway version ==="
    kubectl get deployment gateway -o jsonpath='{.metadata.labels.version}{"\n"}'
  } | tee "$VERIFY_LOG"

  kill "$PF" 2>/dev/null || true
}

run_task2() {
  PF=$(argocd_login)
  git checkout "$BRANCH"
  git pull origin "$BRANCH"

  cp k8s/gateway.yaml /tmp/gateway.yaml.good
  sed -i.bak 's|quickticket-gateway:[^"]*|quickticket-gateway:does-not-exist|' k8s/gateway.yaml
  git add -f k8s/gateway.yaml
  git commit -m "feat: deploy new gateway version"
  git push origin "$BRANCH"

  "$ARGOCD" app sync quickticket || true
  sleep 20
  {
    echo "=== DEGRADED ==="
    "$ARGOCD" app get quickticket
    kubectl get pods -n default
  } | tee "$TASK2_LOG"

  T0=$(date +%s)
  git revert HEAD --no-edit
  git push origin "$BRANCH"
  "$ARGOCD" app sync quickticket
  kubectl wait --for=condition=available deployment/gateway -n default --timeout=300s
  T1=$(date +%s)
  {
    echo "Recovery time: $((T1 - T0)) seconds"
    echo "=== git log ==="
    git log --oneline -3
    echo "=== HEALTHY ==="
    "$ARGOCD" app get quickticket
    kubectl get pods -n default
  } | tee -a "$TASK2_LOG"

  kill "$PF" 2>/dev/null || true
  rm -f k8s/gateway.yaml.bak
}

ensure_podman
fix_cpuset
ensure_k3d
setup_argocd
run_task2
echo "=== ALL DONE === logs: $VERIFY_LOG $TASK2_LOG"

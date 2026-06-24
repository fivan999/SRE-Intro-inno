#!/usr/bin/env bash
# Lab 5 — steps 5.3–5.5 (labs/lab5.md). No blind sleep loops.
set -euo pipefail

PODMAN="${PODMAN:-/opt/homebrew/bin/podman}"
export DOCKER_HOST=unix:///var/run/docker.sock
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
BRANCH="${LAB_BRANCH:-feature/lab5}"

wait_pf() {
  local url=$1 max=${2:-30} i=0
  until curl -sf "$url" >/dev/null 2>&1; do
    i=$((i + 1)); [ "$i" -ge "$max" ] && return 1
    sleep 1
  done
}

echo "=== Podman (skip if already running, 8GB) ==="
"$PODMAN" machine start 2>/dev/null || true
MEM=$("$PODMAN" machine inspect --format '{{.Resources.Memory}}' 2>/dev/null || echo 0)
if [ "$MEM" != "8589934592" ] && [ "$MEM" != "8192" ]; then
  echo "WARN: VM memory is $MEM bytes — expected 8GB. Run: podman machine set --memory 8192 && podman machine restart"
fi

echo "=== cpuset delegation (k3s on rootless Podman) ==="
"$PODMAN" machine ssh bash -e <<'EOF'
sudo mkdir -p /etc/systemd/system/user@.service.d
printf '[Service]\nDelegate=cpu cpuset io memory pids\n' | sudo tee /etc/systemd/system/user@.service.d/delegate.conf
sudo systemctl daemon-reload
EOF

echo "=== 5.4 k3d ==="
if ! kubectl get nodes 2>/dev/null | grep -q Ready; then
  k3d cluster delete quickticket 2>/dev/null || true
  k3d cluster create quickticket \
    --k3s-arg '--kubelet-arg=feature-gates=KubeletInUserNamespace=true@server:*' \
    --timeout 300s --wait
fi
kubectl get nodes

echo "=== 5.3 ghcr-secret ==="
kubectl delete secret ghcr-secret 2>/dev/null || true
kubectl create secret docker-registry ghcr-secret \
  --docker-server=ghcr.io \
  --docker-username=fivan999 \
  --docker-password="$(gh auth token)"

echo "=== 5.4 ArgoCD ==="
kubectl create namespace argocd 2>/dev/null || true
kubectl apply -n argocd --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl wait --for=condition=Available deployment/argocd-server -n argocd --timeout=180s
echo -n "ArgoCD admin password: "
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
echo

echo "=== 5.5 ArgoCD Application ==="
if ! command -v argocd >/dev/null 2>&1; then
  [ -x /tmp/argocd ] || curl -sSL -o /tmp/argocd https://github.com/argoproj/argo-cd/releases/latest/download/argocd-darwin-arm64
  chmod +x /tmp/argocd
fi
ARGOCD=$(command -v argocd 2>/dev/null || echo /tmp/argocd)

pkill -f 'port-forward svc/argocd-server' 2>/dev/null || true
kubectl port-forward svc/argocd-server -n argocd 8443:443 >/tmp/argocd-pf.log 2>&1 &
PF_PID=$!
wait_pf https://localhost:8443 30 || { kill $PF_PID 2>/dev/null; exit 1; }

ADMIN_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
"$ARGOCD" login localhost:8443 --insecure --username admin --password "$ADMIN_PASS"

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

echo "=== sync + wait (kubectl wait, not sleep) ==="
"$ARGOCD" app sync quickticket
for d in postgres redis gateway events payments; do
  kubectl wait --for=condition=available "deployment/$d" -n default --timeout=300s
done
"$ARGOCD" app wait quickticket --sync --health --timeout 300

echo "=== seed DB ==="
PGPOD=$(kubectl get pod -l app=postgres -n default -o jsonpath='{.items[0].metadata.name}')
kubectl exec -i "$PGPOD" -- psql -U quickticket -d quickticket < app/seed.sql | tail -2

echo "=== verify ==="
"$ARGOCD" app get quickticket
kubectl get pods -n default
kubectl get deployment gateway -o jsonpath='version={.metadata.labels.version}{"\n"}'

kill $PF_PID 2>/dev/null || true
echo "=== DONE ==="

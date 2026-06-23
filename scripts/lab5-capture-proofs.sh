#!/usr/bin/env bash
set -euo pipefail
export DOCKER_HOST=unix:///var/run/docker.sock
cd "$(dirname "$0")/.."
ARGOCD=/tmp/argocd
OUT=/tmp/lab5-proofs.txt

[ -x "$ARGOCD" ] || (curl -sSL -o "$ARGOCD" https://github.com/argoproj/argo-cd/releases/latest/download/argocd-darwin-arm64 && chmod +x "$ARGOCD")

pkill -f 'port-forward svc/argocd-server' 2>/dev/null || true
kubectl port-forward svc/argocd-server -n argocd 8443:443 >/tmp/argocd-pf.log 2>&1 &
PF=$!
trap 'kill $PF 2>/dev/null' EXIT
for i in $(seq 1 30); do curl -sfk https://localhost:8443 >/dev/null 2>&1 && break; sleep 1; done

PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)
"$ARGOCD" login localhost:8443 --insecure --username admin --password "$PASS" >/dev/null

{
  echo "=== PROOF 5.7 argocd app get (Synced + Healthy) ==="
  "$ARGOCD" app get quickticket
  echo "=== PROOF 5.6 GitOps version label ==="
  kubectl get deployment gateway -o jsonpath='{.metadata.labels.version}{"\n"}'
  echo "=== PROOF bonus image tag in cluster ==="
  kubectl get deployment gateway -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
  echo "=== PROOF bonus git log (main) ==="
  git log main --oneline -4
} | tee "$OUT"

echo "Saved to $OUT"

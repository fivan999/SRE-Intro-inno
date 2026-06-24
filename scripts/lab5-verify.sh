#!/usr/bin/env bash
# Quick verification outputs for submissions/lab5.md (run when cluster is up)
set -euo pipefail
export DOCKER_HOST=unix:///var/run/docker.sock
ARGOCD=$(command -v argocd 2>/dev/null || echo /tmp/argocd)

pkill -f 'port-forward svc/argocd-server' 2>/dev/null || true
kubectl port-forward svc/argocd-server -n argocd 8443:443 >/tmp/argocd-pf.log 2>&1 &
PF=$!
trap 'kill $PF 2>/dev/null' EXIT

for i in $(seq 1 30); do curl -sfk https://localhost:8443 >/dev/null 2>&1 && break; sleep 1; done
PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)
"$ARGOCD" login localhost:8443 --insecure --username admin --password "$PASS"

echo "=== argocd app get quickticket ==="
"$ARGOCD" app get quickticket
echo "=== gateway version label ==="
kubectl get deployment gateway -o jsonpath='{.metadata.labels.version}{"\n"}'
echo "=== pods ==="
kubectl get pods -n default

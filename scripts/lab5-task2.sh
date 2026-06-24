#!/usr/bin/env bash
# Lab 5 Task 2 — bad deploy + git revert rollback (labs/lab5.md §5.8–5.9)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
BRANCH="${LAB_BRANCH:-feature/lab5}"
export DOCKER_HOST=unix:///var/run/docker.sock
ARGOCD=$(command -v argocd 2>/dev/null || echo /tmp/argocd)
OUT=/tmp/lab5-task2.log

argocd_login() {
  pkill -f 'port-forward svc/argocd-server' 2>/dev/null || true
  kubectl port-forward svc/argocd-server -n argocd 8443:443 >/tmp/argocd-pf.log 2>&1 &
  PF_PID=$!
  for i in $(seq 1 30); do curl -sfk https://localhost:8443 >/dev/null 2>&1 && break; sleep 1; done
  PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)
  "$ARGOCD" login localhost:8443 --insecure --username admin --password "$PASS"
  echo "$PF_PID"
}

{
  echo "=== Task 2: bad deploy ==="
  git checkout "$BRANCH"
  git pull origin "$BRANCH"

  sed -i.bak 's|quickticket-gateway:[^"]*|quickticket-gateway:does-not-exist|' k8s/gateway.yaml
  git add -f k8s/gateway.yaml
  git commit -m "feat: deploy new gateway version"
  git push origin "$BRANCH"

  PF=$(argocd_login)
  "$ARGOCD" app sync quickticket || true
  sleep 15
  echo "--- argocd (degraded) ---"
  "$ARGOCD" app get quickticket
  echo "--- kubectl get pods ---"
  kubectl get pods -n default

  echo "=== Task 2: git revert ==="
  T0=$(date +%s)
  git revert HEAD --no-edit
  git push origin "$BRANCH"
  "$ARGOCD" app sync quickticket
  kubectl wait --for=condition=available deployment/gateway -n default --timeout=300s
  T1=$(date +%s)
  echo "Recovery time: $((T1 - T0)) seconds"

  echo "--- git log ---"
  git log --oneline -3
  echo "--- argocd (healthy) ---"
  "$ARGOCD" app get quickticket
  echo "--- kubectl get pods ---"
  kubectl get pods -n default

  kill "$PF" 2>/dev/null || true
  rm -f k8s/gateway.yaml.bak
} 2>&1 | tee "$OUT"

echo "Output saved to $OUT"

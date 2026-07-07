#!/usr/bin/env bash
# Lab 9 — Alembic migrations, pg_dump/restore, DR, PVC + CronJob backup
set -euo pipefail

export PATH="${HOME}/.local/bin:/opt/homebrew/bin:${PATH}"
export DOCKER_HOST="${DOCKER_HOST:-unix:///var/run/docker.sock}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${OUT:-/tmp/lab9-proofs.txt}"
ARCH="$(uname -m)"
case "$ARCH" in
  arm64|aarch64) ROLLOUTS_ARCH=darwin-arm64 ;;
  *) ROLLOUTS_ARCH=linux-amd64 ;;
esac
cd "$REPO_ROOT"

prom_query() {
  kubectl exec -n monitoring deployment/prometheus -- wget -qO- \
    "http://localhost:9090/api/v1/query?query=$1" 2>/dev/null \
    | python3 -c "import sys,json; r=json.load(sys.stdin)['data']['result']; print(r[0]['value'][1] if r else 'no data')"
}

pg_pod() {
  kubectl get pod -l app=postgres -o jsonpath='{.items[0].metadata.name}'
}

ensure_rollouts_plugin() {
  if command -v kubectl-argo-rollouts >/dev/null 2>&1; then return; fi
  mkdir -p "${HOME}/.local/bin"
  curl -fsSL -o "${HOME}/.local/bin/kubectl-argo-rollouts" \
    "https://github.com/argoproj/argo-rollouts/releases/latest/download/kubectl-argo-rollouts-${ROLLOUTS_ARCH}"
  chmod +x "${HOME}/.local/bin/kubectl-argo-rollouts"
}

install_rollouts() {
  kubectl create namespace argo-rollouts 2>/dev/null || true
  kubectl apply -n argo-rollouts -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml
  kubectl wait --for=condition=Available deployment/argo-rollouts -n argo-rollouts --timeout=120s
}

ensure_cluster() {
  if ! kubectl get nodes >/dev/null 2>&1; then
    /opt/homebrew/bin/podman machine start 2>/dev/null || true
    /opt/homebrew/bin/podman machine ssh bash -e <<'EOF' 2>/dev/null || true
sudo mkdir -p /etc/systemd/system/user@.service.d
printf '[Service]\nDelegate=cpu cpuset io memory pids\n' | sudo tee /etc/systemd/system/user@.service.d/delegate.conf
sudo systemctl daemon-reload
EOF
    k3d cluster delete quickticket 2>/dev/null || true
    k3d cluster create quickticket \
      --k3s-arg '--kubelet-arg=feature-gates=KubeletInUserNamespace=true@server:*' \
      --timeout 300s --wait
  fi
  kubectl wait --for=condition=Ready node --all --timeout=120s
}

deploy_ephemeral_postgres() {
  kubectl delete cronjob postgres-backup --ignore-not-found 2>/dev/null || true
  kubectl delete deployment postgres --ignore-not-found 2>/dev/null || true
  kubectl delete pvc postgres-data --ignore-not-found 2>/dev/null || true
  sleep 3
  kubectl apply -f - <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgres
spec:
  replicas: 1
  selector:
    matchLabels:
      app: postgres
  template:
    metadata:
      labels:
        app: postgres
    spec:
      containers:
        - name: postgres
          image: postgres:17-alpine
          ports:
            - containerPort: 5432
          env:
            - name: POSTGRES_DB
              value: quickticket
            - name: POSTGRES_USER
              value: quickticket
            - name: POSTGRES_PASSWORD
              value: quickticket
          readinessProbe:
            exec:
              command: ["pg_isready", "-U", "quickticket"]
            periodSeconds: 5
          livenessProbe:
            exec:
              command: ["pg_isready", "-U", "quickticket"]
            initialDelaySeconds: 15
            periodSeconds: 10
---
apiVersion: v1
kind: Service
metadata:
  name: postgres
spec:
  selector:
    app: postgres
  ports:
    - port: 5432
      targetPort: 5432
YAML
  kubectl rollout status deployment/postgres --timeout=120s
}

deploy_stack() {
  if ! kubectl get secret ghcr-secret >/dev/null 2>&1; then
    kubectl create secret docker-registry ghcr-secret \
      --docker-server=ghcr.io --docker-username=fivan999 \
      --docker-password="$(gh auth token)" 2>/dev/null || true
  fi
  ensure_rollouts_plugin
  install_rollouts
  deploy_ephemeral_postgres
  kubectl apply -f "$REPO_ROOT/k8s/redis.yaml"
  kubectl apply -f "$REPO_ROOT/k8s/events.yaml"
  kubectl apply -f "$REPO_ROOT/k8s/payments.yaml"
  kubectl delete deployment gateway --ignore-not-found 2>/dev/null || true
  kubectl apply -f "$REPO_ROOT/labs/lab7/analysis-template.yaml"
  kubectl apply -f "$REPO_ROOT/k8s/gateway.yaml"
  kubectl argo rollouts status gateway --timeout=300s 2>/dev/null \
    || kubectl-argo-rollouts status gateway --timeout=300s
  kubectl rollout status deployment/events --timeout=180s
  kubectl rollout status deployment/payments --timeout=180s
  kubectl apply -f "$REPO_ROOT/labs/lab7/prometheus.yaml"
  kubectl apply -f "$REPO_ROOT/labs/lab8/mixedload.yaml"
  kubectl rollout status deployment/mixedload --timeout=60s
}

wait_pg_ready() {
  local i
  for i in $(seq 1 30); do
    if kubectl get pod -l app=postgres -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q True; then
      return 0
    fi
    sleep 2
  done
  echo "postgres pod not ready" >&2
  kubectl get pods -l app=postgres
  return 1
}

{
  echo "=== Lab 9 proofs ==="
  ensure_cluster
  deploy_stack

  kubectl exec -i "$(kubectl get pod -l app=postgres -o name)" -- \
    psql -U quickticket -d quickticket < "$REPO_ROOT/app/seed.sql" >/dev/null
  echo "Waiting 90s for mixedload traffic + orders..."
  sleep 90

  echo ""
  echo "=== 9.1-9.3 Alembic ==="
  python3 -m venv .venv 2>/dev/null || true
  .venv/bin/pip install -q alembic==1.18.4 psycopg2-binary==2.9.11 sqlalchemy==2.0.49
  pkill -f "port-forward.*5432" 2>/dev/null || true
  kubectl port-forward svc/postgres 5432:5432 >/tmp/pg-pf.log 2>&1 &
  PF=$!; sleep 3

  .venv/bin/alembic stamp a1b2c3d4e5f6
  echo "--- alembic history ---"
  .venv/bin/alembic history
  echo "--- alembic current (before upgrade) ---"
  .venv/bin/alembic current

  echo ""
  echo "=== 9.4 Migration under load ==="
  echo "5xx before: $(prom_query 'sum(increase(gateway_requests_total%7Bstatus%3D~%225..%22%7D%5B1m%5D))')"
  echo "--- time alembic upgrade head ---"
  time .venv/bin/alembic upgrade head
  echo "5xx after: $(prom_query 'sum(increase(gateway_requests_total%7Bstatus%3D~%225..%22%7D%5B1m%5D))')"
  kubectl exec "$(pg_pod)" -- psql -U quickticket -d quickticket -c '\d events'

  echo ""
  echo "=== 9.5 pg_dump backup ==="
  kubectl exec "$(pg_pod)" -- pg_dump -U quickticket -Fc quickticket > /tmp/quickticket.dump
  ls -lh /tmp/quickticket.dump
  file /tmp/quickticket.dump
  kubectl cp /tmp/quickticket.dump "$(pg_pod):/tmp/backup.dump"
  kubectl exec "$(pg_pod)" -- pg_restore --list /tmp/backup.dump | head -20

  echo ""
  echo "=== 9.6 DROP + restore ==="
  echo "Before:"
  kubectl exec "$(pg_pod)" -- psql -U quickticket -d quickticket \
    -c 'SELECT count(*) AS events FROM events; SELECT count(*) AS orders FROM orders;'
  kubectl exec "$(pg_pod)" -- psql -U quickticket -d quickticket -c 'DROP TABLE orders CASCADE'
  echo "After DROP:"
  kubectl exec "$(pg_pod)" -- psql -U quickticket -d quickticket \
    -c 'SELECT count(*) AS events FROM events;' 2>&1 || true
  kubectl exec "$(pg_pod)" -- pg_restore -U quickticket -d quickticket --clean --if-exists /tmp/backup.dump
  echo "After restore:"
  kubectl exec "$(pg_pod)" -- psql -U quickticket -d quickticket \
    -c 'SELECT count(*) AS events FROM events; SELECT count(*) AS orders FROM orders;'

  kill $PF 2>/dev/null || true

  echo ""
  echo "=== 9.8 Task 2: Kill Postgres (no PVC) ==="
  ORDERS_BEFORE=$(kubectl exec "$(pg_pod)" -- psql -U quickticket -d quickticket -tAc 'SELECT count(*) FROM orders')
  T0=$(date +%H:%M:%S)
  echo "healthy at $T0, orders=$ORDERS_BEFORE"
  kubectl delete pod -l app=postgres --grace-period=0 --force
  T_KILL=$(date +%H:%M:%S)
  wait_pg_ready
  T_READY=$(date +%H:%M:%S)
  NEW_POD=$(pg_pod)
  echo "Tables after kill (no PVC):"
  kubectl exec "$NEW_POD" -- psql -U quickticket -d quickticket -c '\dt' 2>&1 || true
  kubectl cp /tmp/quickticket.dump "$NEW_POD:/tmp/backup.dump"
  kubectl exec "$NEW_POD" -- pg_restore -U quickticket -d quickticket --clean --if-exists /tmp/backup.dump
  T_RESTORED=$(date +%H:%M:%S)
  kubectl rollout restart deployment/events
  kubectl rollout status deployment/events --timeout=60s
  T_APP_READY=$(date +%H:%M:%S)
  ORDERS_AFTER=$(kubectl exec "$NEW_POD" -- psql -U quickticket -d quickticket -tAc 'SELECT count(*) FROM orders' 2>/dev/null || echo 0)
  echo "T_KILL=$T_KILL T_READY=$T_READY T_RESTORED=$T_RESTORED T_APP_READY=$T_APP_READY"
  echo "orders before=$ORDERS_BEFORE after restore=$ORDERS_AFTER"
  echo "error_rate=$(prom_query 'sum(rate(gateway_requests_total%7Bstatus%3D~%225..%22%7D%5B30s%5D))')"

  echo ""
  echo "=== Bonus B.1: PVC Postgres ==="
  kubectl delete deployment postgres --ignore-not-found
  kubectl delete pvc postgres-data --ignore-not-found 2>/dev/null || true
  sleep 5
  kubectl apply -f "$REPO_ROOT/k8s/postgres.yaml"
  kubectl rollout status deployment/postgres --timeout=120s
  kubectl exec -i "$(kubectl get pod -l app=postgres -o name)" -- \
    psql -U quickticket -d quickticket < "$REPO_ROOT/app/seed.sql"
  pkill -f "port-forward.*5432" 2>/dev/null || true
  kubectl port-forward svc/postgres 5432:5432 >/tmp/pg-pf2.log 2>&1 &
  PF2=$!; sleep 3
  .venv/bin/alembic upgrade head 2>/dev/null || true
  kill $PF2 2>/dev/null || true
  kubectl exec "$(pg_pod)" -- psql -U quickticket -d quickticket -tAc 'SELECT count(*) FROM events'

  echo "Kill with PVC:"
  EVENTS_BEFORE=$(kubectl exec "$(pg_pod)" -- psql -U quickticket -d quickticket -tAc 'SELECT count(*) FROM events')
  T_KILL2=$(date +%H:%M:%S)
  kubectl delete pod -l app=postgres --grace-period=0 --force
  wait_pg_ready
  T_READY2=$(date +%H:%M:%S)
  EVENTS_AFTER=$(kubectl exec "$(pg_pod)" -- psql -U quickticket -d quickticket -tAc 'SELECT count(*) FROM events')
  echo "PVC kill: T_KILL=$T_KILL2 T_READY=$T_READY2 events_after=$EVENTS_AFTER (before=$EVENTS_BEFORE)"

  echo ""
  echo "=== Bonus B.2: CronJob backup ==="
  kubectl apply -f "$REPO_ROOT/labs/lab9/backup-storage.yaml"
  kubectl rollout status deployment/backup-inspector --timeout=60s
  kubectl apply -f "$REPO_ROOT/k8s/backup-cronjob.yaml"
  for i in $(seq 1 7); do
    kubectl delete job "manual-$i" --ignore-not-found 2>/dev/null || true
    kubectl create job --from=cronjob/postgres-backup "manual-$i"
    kubectl wait --for=condition=Complete "job/manual-$i" --timeout=90s
    kubectl logs "job/manual-$i" | tail -5
  done
  echo "--- backup files ---"
  kubectl exec deployment/backup-inspector -- ls -la /backups

} | tee "$OUT"

echo "Proofs saved to $OUT"

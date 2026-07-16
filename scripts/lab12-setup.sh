#!/usr/bin/env bash
# Lab 12 — PDB, graceful shutdown, CONCURRENTLY migration, expand-and-contract
set -euo pipefail

export PATH="${HOME}/.local/bin:/opt/homebrew/bin:${PATH}"
export DOCKER_HOST="${DOCKER_HOST:-unix:///var/run/docker.sock}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${OUT:-/tmp/lab12-proofs.txt}"
cd "$REPO_ROOT"

prom_5xx() {
  local win="${1:-1m}"
  kubectl exec -n monitoring deployment/prometheus -- wget -qO- \
    "http://localhost:9090/api/v1/query?query=sum(increase(gateway_requests_total%7Bstatus%3D~%225..%22%7D%5B${win}%5D))" 2>/dev/null \
    | python3 -c "import sys,json; r=json.load(sys.stdin)['data']['result']; print(r[0]['value'][1] if r else '0')"
}

build_images() {
  docker build -t quickticket-gateway:v1 ./app/gateway
  docker build -t quickticket-events:v1 ./app/events
  docker build -t quickticket-notifications:v1 ./app/notifications
  docker build -t quickticket-payments:v1 ./app/payments
  docker save \
    quickticket-gateway:v1 \
    quickticket-events:v1 \
    quickticket-notifications:v1 \
    quickticket-payments:v1 \
    -o /tmp/quickticket-images.tar
  k3d image import -c quickticket /tmp/quickticket-images.tar
  sleep 20
  export KUBECONFIG="$(k3d kubeconfig write quickticket)"
  for i in $(seq 1 30); do
    kubectl get nodes >/dev/null 2>&1 && break
    sleep 5
  done
}

deploy_stack() {
  kubectl create namespace argo-rollouts 2>/dev/null || true
  kubectl apply -n argo-rollouts -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml
  kubectl wait --for=condition=Available deployment/argo-rollouts -n argo-rollouts --timeout=120s
  kubectl apply -f "$REPO_ROOT/k8s/postgres.yaml"
  kubectl apply -f "$REPO_ROOT/k8s/redis.yaml"
  kubectl apply -f "$REPO_ROOT/k8s/events.yaml"
  kubectl apply -f "$REPO_ROOT/k8s/payments.yaml"
  kubectl apply -f "$REPO_ROOT/k8s/notifications.yaml"
  kubectl apply -f "$REPO_ROOT/labs/lab7/analysis-template.yaml"
  kubectl apply -f "$REPO_ROOT/k8s/gateway.yaml"
  kubectl apply -f "$REPO_ROOT/k8s/pdb.yaml"
  kubectl rollout status deployment/postgres --timeout=180s
  kubectl argo rollouts status gateway --timeout=300s 2>/dev/null || true
  kubectl rollout status deployment/events --timeout=180s
  kubectl rollout status deployment/payments --timeout=180s
  kubectl rollout status deployment/notifications --timeout=120s
  kubectl apply -f "$REPO_ROOT/labs/lab7/prometheus.yaml"
  kubectl apply -f "$REPO_ROOT/labs/lab8/mixedload.yaml"
  kubectl rollout status deployment/mixedload --timeout=60s
  kubectl -n monitoring rollout status deployment/prometheus --timeout=120s 2>/dev/null || true
}

seed_legacy() {
  kubectl exec -i "$(kubectl get pod -l app=postgres -o name | head -1)" -- psql -U quickticket -d quickticket <<'SQL'
DROP TABLE IF EXISTS orders CASCADE;
DROP TABLE IF EXISTS events CASCADE;
CREATE TABLE events (
    id SERIAL PRIMARY KEY,
    name TEXT NOT NULL,
    venue TEXT NOT NULL,
    event_date TIMESTAMPTZ NOT NULL,
    total_tickets INT NOT NULL,
    price_cents INT NOT NULL
);
CREATE TABLE orders (
    id TEXT PRIMARY KEY,
    event_id INT REFERENCES events(id),
    quantity INT NOT NULL,
    total_cents INT NOT NULL,
    payment_ref TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'confirmed',
    created_at TIMESTAMPTZ DEFAULT now()
);
INSERT INTO events (name, venue, event_date, total_tickets, price_cents) VALUES
  ('Go Conference 2026', 'Main Hall A', '2026-09-15 09:00:00+00', 100, 5000),
  ('SRE Meetup', 'Room 204', '2026-10-01 18:00:00+00', 30, 0),
  ('Cloud Native Summit', 'Expo Center', '2026-11-20 10:00:00+00', 500, 15000),
  ('Python Workshop', 'Lab 301', '2026-09-22 14:00:00+00', 25, 2000),
  ('Kubernetes Deep Dive', 'Auditorium B', '2026-10-10 10:00:00+00', 80, 8000);
SQL
}

prepare_legacy_events() {
  cp "$REPO_ROOT/app/events/main.py" "$REPO_ROOT/app/events/main_deploy_b.py"
  sed \
    -e 's/e\.scheduled_at/e.event_date/g' \
    -e 's/ORDER BY e\.event_date/ORDER BY e.event_date/g' \
    "$REPO_ROOT/app/events/main_deploy_b.py" > "$REPO_ROOT/app/events/main.py"
}

main() {
  echo "=== Lab 12 proofs ==="
  podman machine start 2>/dev/null || true
  sleep 3
  export DOCKER_HOST="${DOCKER_HOST:-unix:///var/run/docker.sock}"
  if ! kubectl get nodes >/dev/null 2>&1; then
    k3d cluster delete quickticket 2>/dev/null || true
    sleep 2
    k3d cluster create quickticket \
      --k3s-arg '--kubelet-arg=feature-gates=KubeletInUserNamespace=true@server:*' \
      --timeout 600s --wait
  elif ! kubectl wait --for=condition=Ready node --all --timeout=30s >/dev/null 2>&1; then
    k3d cluster delete quickticket 2>/dev/null || true
    sleep 2
    k3d cluster create quickticket \
      --k3s-arg '--kubelet-arg=feature-gates=KubeletInUserNamespace=true@server:*' \
      --timeout 600s --wait
  fi
  k3d kubeconfig merge quickticket --kubeconfig-switch-context >/dev/null 2>&1 || true
  export KUBECONFIG="${KUBECONFIG:-$(k3d kubeconfig write quickticket)}"
  kubectl wait --for=condition=Ready node --all --timeout=120s
  prepare_legacy_events
  build_images
  deploy_stack
  seed_legacy
  python3 -m venv .venv 2>/dev/null || true
  .venv/bin/pip install -q alembic==1.18.4 psycopg2-binary==2.9.11 sqlalchemy==2.0.49
  pkill -f "port-forward.*5432" 2>/dev/null || true
  kubectl port-forward svc/postgres 5432:5432 >/tmp/pg-pf.log 2>&1 &
  PF=$!; sleep 3
  .venv/bin/alembic stamp a1b2c3d4e5f6
  .venv/bin/alembic upgrade b2c3d4e5f6a7
  sleep 20

  echo ""
  echo "=== Task 1: replicas ==="
  kubectl get deploy,rollout

  echo ""
  echo "=== Task 1: pod kill 5xx ==="
  echo "5xx before: $(prom_5xx 3m)"
  GW=$(kubectl get pod -l app=gateway -o jsonpath='{.items[0].metadata.name}')
  EV=$(kubectl get pod -l app=events -o jsonpath='{.items[0].metadata.name}')
  kubectl delete pod "$GW" "$EV" --wait=false
  sleep 15
  echo "5xx after: $(prom_5xx 1m)"

  echo ""
  echo "=== Task 1: PDB ==="
  kubectl get pdb
  kubectl get rollout gateway -o jsonpath='{.spec.template.spec.topologySpreadConstraints}' | python3 -m json.tool
  kubectl get pod -l app=gateway -o wide

  echo ""
  echo "=== Task 1: PDB eviction block ==="
  kubectl patch pdb events-pdb --type=merge -p '{"spec":{"minAvailable":2}}'
  kubectl proxy --port=8901 >/tmp/proxy.log 2>&1 &
  PROXY_PID=$!
  sleep 2
  POD=$(kubectl get pod -l app=events -o jsonpath='{.items[0].metadata.name}')
  curl -s -X POST -H 'Content-Type: application/json' \
    -d "{\"apiVersion\":\"policy/v1\",\"kind\":\"Eviction\",\"metadata\":{\"name\":\"$POD\",\"namespace\":\"default\"}}" \
    "http://localhost:8901/api/v1/namespaces/default/pods/$POD/eviction" | python3 -m json.tool || true
  kill $PROXY_PID 2>/dev/null || true
  kubectl patch pdb events-pdb --type=merge -p '{"spec":{"minAvailable":1}}'

  echo ""
  echo "=== Task 2: rolling restart 5xx ==="
  echo "5xx before restart: $(prom_5xx 1m)"
  kubectl argo rollouts restart gateway
  kubectl argo rollouts status gateway --timeout=300s
  sleep 10
  echo "5xx after restart: $(prom_5xx 3m)"

  echo ""
  echo "=== Task 2: CONCURRENTLY index ==="
  echo "5xx before migration: $(prom_5xx 1m)"
  time .venv/bin/alembic upgrade c3d4e5f6a7b8
  kubectl exec "$(kubectl get pod -l app=postgres -o jsonpath='{.items[0].metadata.name}')" -- \
    psql -U quickticket -d quickticket -c '\d events' | grep idx_events || true
  echo "5xx after migration: $(prom_5xx 1m)"

  echo ""
  echo "=== Bonus: expand-and-contract ==="
  echo "5xx baseline: $(prom_5xx 1m)" | tee /tmp/5xx.baseline
  cp "$REPO_ROOT/app/events/main_deploy_b.py" /tmp/events-deploy-b.py
  .venv/bin/alembic upgrade d4e5f6a7b8c9
  sleep 5
  echo "5xx after M1: $(prom_5xx 1m)"
  sed 's/e\.scheduled_at/COALESCE(e.scheduled_at, e.event_date)/g' /tmp/events-deploy-b.py > "$REPO_ROOT/app/events/main.py"
  docker build -t quickticket-events:v1 ./app/events
  docker save quickticket-events:v1 -o /tmp/quickticket-events.tar
  k3d image import -c quickticket /tmp/quickticket-events.tar
  kubectl rollout restart deployment/events && kubectl rollout status deployment/events --timeout=120s
  sleep 5
  echo "5xx after Deploy A: $(prom_5xx 1m)"
  .venv/bin/alembic upgrade e5f6a7b8c9d0
  sleep 5
  echo "5xx after M2: $(prom_5xx 1m)"
  cp /tmp/events-deploy-b.py "$REPO_ROOT/app/events/main.py"
  docker build -t quickticket-events:v1 ./app/events
  docker save quickticket-events:v1 -o /tmp/quickticket-events.tar
  k3d image import -c quickticket /tmp/quickticket-events.tar
  kubectl rollout restart deployment/events && kubectl rollout status deployment/events --timeout=120s
  .venv/bin/alembic upgrade f6a7b8c9d0e1
  sleep 5
  echo "5xx final: $(prom_5xx 1m)" | tee /tmp/5xx.final
  kubectl exec "$(kubectl get pod -l app=postgres -o jsonpath='{.items[0].metadata.name}')" -- \
    psql -U quickticket -d quickticket -c '\d events'
  cp "$REPO_ROOT/app/events/main_deploy_b.py" "$REPO_ROOT/app/events/main.py"
  rm -f "$REPO_ROOT/app/events/main_deploy_b.py"

  kill $PF 2>/dev/null || true
}

main 2>&1 | tee "$OUT"
echo "Proofs saved to $OUT"

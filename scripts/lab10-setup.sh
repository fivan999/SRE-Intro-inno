#!/usr/bin/env bash
# Lab 10 — in-cluster Locust load tests, DORA metrics, capacity sampling
set -euo pipefail

export PATH="${HOME}/.local/bin:/opt/homebrew/bin:${PATH}"
export DOCKER_HOST="${DOCKER_HOST:-unix:///var/run/docker.sock}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${OUT:-/tmp/lab10-proofs.txt}"
cd "$REPO_ROOT"

flush_redis() {
  kubectl exec -i "$(kubectl get pod -l app=redis -o name)" -- redis-cli FLUSHDB >/dev/null
}

run_load() {
  local name=$1 users=$2 ramp=$3
  kubectl delete job "$name" --ignore-not-found 2>/dev/null || true
  flush_redis
  sleep 2
  kubectl apply -f - <<YAML
apiVersion: batch/v1
kind: Job
metadata:
  name: ${name}
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 600
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: locust
          image: locustio/locust:2.43.4
          command: ["locust"]
          args:
            - "-f"
            - "/mnt/locust/locustfile.py"
            - "--host=http://gateway:8080"
            - "--headless"
            - "-u"
            - "${users}"
            - "-r"
            - "${ramp}"
            - "-t"
            - "60s"
            - "--only-summary"
          volumeMounts:
            - name: locustfile
              mountPath: /mnt/locust
      volumes:
        - name: locustfile
          configMap:
            name: locustfile
YAML
  kubectl wait --for=condition=Complete "job/${name}" --timeout=180s 2>/dev/null \
    || kubectl wait --for=condition=Failed "job/${name}" --timeout=30s
  echo "=== ${name} (${users} users, ramp ${ramp}/s) ==="
  kubectl logs "job/${name}"
  echo ""
}

{
  echo "=== Lab 10 proofs ==="
  kubectl get nodes >/dev/null

  cp "$REPO_ROOT/labs/lab10/locustfile.py" "$REPO_ROOT/locustfile.py"
  kubectl create configmap locustfile \
    --from-file=locustfile.py="$REPO_ROOT/locustfile.py" \
    --dry-run=client -o yaml | kubectl apply -f -

  # Re-seed if needed
  kubectl exec -i "$(kubectl get pod -l app=postgres -o name)" -- \
    psql -U quickticket -d quickticket -c 'SELECT count(*) FROM events;' 2>/dev/null || \
    kubectl exec -i "$(kubectl get pod -l app=postgres -o name)" -- \
      psql -U quickticket -d quickticket < "$REPO_ROOT/app/seed.sql"

  run_load load-10 10 2
  run_load load-50 50 5
  run_load load-100 100 10
  run_load load-200 200 20

  echo "=== Breaking point: kubectl top pods ==="
  kubectl top pods -l app=gateway 2>/dev/null || echo "(metrics-server warming up)"
  kubectl top pods -l app=events 2>/dev/null || true
  kubectl top pods -l app=payments 2>/dev/null || true

  echo ""
  echo "=== DORA source data ==="
  echo "git commits on main: $(git log --oneline main | wc -l | tr -d ' ')"
  echo "gateway ReplicaSets: $(kubectl get rs -l app=gateway -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | wc -l | tr -d ' ')"
  echo "AnalysisRun phases:"
  kubectl get analysisrun -o jsonpath='{.items[*].status.phase}' 2>/dev/null | tr ' ' '\n' | sort | uniq -c || echo "none"

} | tee "$OUT"

echo "Proofs saved to $OUT"

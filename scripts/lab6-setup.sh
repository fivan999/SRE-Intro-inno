#!/usr/bin/env bash
# Lab 6 — start stack, configure Grafana alerts, simulate incident, capture proofs
set -euo pipefail

export DOCKER_HOST="${DOCKER_HOST:-unix:///var/run/docker.sock}"
COMPOSE="${COMPOSE:-podman compose}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$REPO_ROOT/app"
OUT=/tmp/lab6-proofs.txt
GRAFANA_URL="${GRAFANA_URL:-http://localhost:3000}"
GRAFANA_USER="${GRAFANA_USER:-admin}"
GRAFANA_PASS="${GRAFANA_PASS:-admin}"

dc() {
  $COMPOSE -f "$APP/docker-compose.yaml" -f "$REPO_ROOT/docker-compose.monitoring.yaml" "$@"
}

wait_url() {
  local url=$1 max=${2:-60} i=0
  until curl -sf "$url" >/dev/null 2>&1; do
    i=$((i + 1)); [ "$i" -ge "$max" ] && return 1
    sleep 2
  done
}

grafana_api() {
  curl -sf -u "$GRAFANA_USER:$GRAFANA_PASS" -H 'Content-Type: application/json' "$@"
}

echo "=== 6.1 Start stack ==="
cd "$APP"
dc up -d --build
wait_url "$GRAFANA_URL/api/health"
wait_url "http://localhost:3080/health"

dc exec -T postgres psql -U quickticket -d quickticket < seed.sql >/dev/null 2>&1 || true

echo "=== 6.2 Contact point (webhook.site) ==="
WEBHOOK_JSON=$(curl -sf -X POST https://webhook.site/token -H 'Content-Type: application/json' -d '{}')
WEBHOOK_UUID=$(echo "$WEBHOOK_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['uuid'])")
WEBHOOK_URL="https://webhook.site/$WEBHOOK_UUID"
echo "Webhook URL: $WEBHOOK_URL"

grafana_api -X POST "$GRAFANA_URL/api/v1/provisioning/contact-points" \
  -H 'X-Disable-Provenance: true' \
  -d "{\"name\":\"quickticket-alerts\",\"type\":\"webhook\",\"settings\":{\"url\":\"$WEBHOOK_URL\",\"httpMethod\":\"POST\"},\"disableResolveMessage\":false}" >/dev/null 2>&1 || true

grafana_api -X PUT "$GRAFANA_URL/api/v1/provisioning/policies" \
  -H 'X-Disable-Provenance: true' \
  -d "{\"receiver\":\"quickticket-alerts\",\"group_by\":[\"alertname\"],\"group_wait\":\"30s\",\"group_interval\":\"5m\",\"repeat_interval\":\"5m\",\"routes\":[]}" >/dev/null

DS_UID=$(grafana_api "$GRAFANA_URL/api/datasources/name/Prometheus" | python3 -c "import sys,json; print(json.load(sys.stdin)['uid'])")
FOLDER_UID=$(grafana_api "$GRAFANA_URL/api/folders" | python3 -c "
import sys,json
folders=json.load(sys.stdin)
print(next((f['uid'] for f in folders if f.get('title')=='QuickTicket'), ''))
" 2>/dev/null || true)
if [ -z "$FOLDER_UID" ]; then
  FOLDER_UID=$(grafana_api -X POST "$GRAFANA_URL/api/folders" -d '{"title":"QuickTicket"}' | python3 -c "import sys,json; print(json.load(sys.stdin)['uid'])")
fi

make_alert() {
  local title=$1 expr=$2 threshold=$3 for_period=$4 severity=$5 summary=$6
  grafana_api -X POST "$GRAFANA_URL/api/v1/provisioning/alert-rules" \
    -H 'X-Disable-Provenance: true' \
    -d "$(python3 <<PY
import json
title, expr, threshold, for_period, severity, summary = """$title""", """$expr""", """$threshold""", """$for_period""", """$severity""", """$summary"""
ds = """$DS_UID"""
folder = """$FOLDER_UID"""
payload = {
  "title": title,
  "ruleGroup": "quickticket",
  "folderUID": folder,
  "noDataState": "NoData",
  "execErrState": "Error",
  "for": for_period,
  "condition": "C",
  "annotations": {"summary": summary},
  "labels": {"severity": severity},
  "data": [
    {"refId": "A", "relativeTimeRange": {"from": 600, "to": 0}, "datasourceUid": ds,
     "model": {"expr": expr, "refId": "A", "intervalMs": 1000, "maxDataPoints": 43200}},
    {"refId": "B", "relativeTimeRange": {"from": 0, "to": 0}, "datasourceUid": "__expr__",
     "model": {"refId": "B", "type": "reduce", "expression": "A", "reducer": "last",
               "datasource": {"type": "__expr__", "uid": "__expr__"}, "intervalMs": 1000, "maxDataPoints": 43200}},
    {"refId": "C", "relativeTimeRange": {"from": 0, "to": 0}, "datasourceUid": "__expr__",
     "model": {"refId": "C", "type": "threshold", "expression": "B",
               "datasource": {"type": "__expr__", "uid": "__expr__"}, "intervalMs": 1000, "maxDataPoints": 43200,
               "conditions": [{"type": "query", "evaluator": {"type": "gt", "params": [float(threshold)]},
                               "operator": {"type": "and"}, "query": {"params": ["C"]},
                               "reducer": {"type": "last", "params": []}}]}}
  ]
}
print(json.dumps(payload))
PY
)" >/dev/null 2>&1 || true
}

echo "=== 6.3 Alert rules ==="
ERROR_EXPR='sum(rate(gateway_requests_total{status=~"5.."}[5m])) / sum(rate(gateway_requests_total[5m])) * 100'
BURN_EXPR='(1 - (sum(rate(gateway_requests_total{status!~"5.."}[30m])) / sum(rate(gateway_requests_total[30m])))) / (1 - 0.995)'
make_alert "QuickTicket High Error Rate" "$ERROR_EXPR" "5" "2m" "critical" 'Gateway error rate is {{ $value }}%'
make_alert "QuickTicket SLO Burn Rate" "$BURN_EXPR" "6" "5m" "warning" "SLO burn rate elevated"

echo "=== loadgen ==="
pkill -f 'loadgen/run.sh' 2>/dev/null || true
pkill -f 'lab6-pay-flood' 2>/dev/null || true
"$APP/loadgen/run.sh" 10 900 >/tmp/lab6-loadgen.log 2>&1 &
sleep 45

echo "=== 6.6 Inject failure (stop payments) ==="
T_INJECT=$(date +%H:%M:%S)
echo "INJECT_AT=$T_INJECT"
dc stop payments
# Pay traffic is only ~10% of loadgen; flood /pay so 5xx rate crosses the 5% threshold.
(
  while true; do
    EVENT_ID=$((RANDOM % 5 + 1))
    RESERVE_RESP=$(curl -sf -X POST -H 'Content-Type: application/json' \
      -d '{"quantity":1}' "http://localhost:3080/events/$EVENT_ID/reserve" 2>/dev/null || echo '{}')
    RES_ID=$(echo "$RESERVE_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('reservation_id',''))" 2>/dev/null || true)
    [ -n "$RES_ID" ] && curl -sf -o /dev/null -X POST "http://localhost:3080/reserve/$RES_ID/pay" 2>/dev/null || true
    sleep 0.1
  done
) >/tmp/lab6-pay-flood.log 2>&1 &
PAY_FLOOD_PID=$!

echo "Waiting for alert to fire (up to 10 min)..."
T_FIRE=""
for i in $(seq 1 60); do
  STATE=$(grafana_api "$GRAFANA_URL/api/v1/provisioning/alert-rules" | python3 -c "
import sys,json
rules=json.load(sys.stdin)
for r in rules:
    if r.get('title')=='QuickTicket High Error Rate':
        print(r.get('lastEvaluation','') or r.get('state','unknown'))
        break
" 2>/dev/null || echo "")
  # also check ruler API
  FIRING=$(grafana_api "$GRAFANA_URL/api/prometheus/grafana/api/v1/rules" 2>/dev/null | python3 -c "
import sys,json
try:
  d=json.load(sys.stdin)
  for g in d.get('data',{}).get('groups',[]):
    for r in g.get('rules',[]):
      if 'High Error Rate' in r.get('name','') and r.get('state')=='firing':
        print('firing'); raise SystemExit
except: pass
" 2>/dev/null || true)
  if [ "$FIRING" = "firing" ]; then T_FIRE=$(date +%H:%M:%S); break; fi
  sleep 10
done
T_DIAG=$(date +%H:%M:%S)

echo "=== Fix ==="
kill "$PAY_FLOOD_PID" 2>/dev/null || pkill -f 'lab6-pay-flood' 2>/dev/null || true
dc start payments
T_FIX=$(date +%H:%M:%S)
sleep 120
T_RESOLVED=$(date +%H:%M:%S)

WEBHOOK_HITS=$(curl -sf "https://webhook.site/token/$WEBHOOK_UUID/requests?sorting=newest" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('data',[])))" 2>/dev/null || echo 0)

{
  echo "=== Lab 6 proofs ==="
  echo "Webhook URL: $WEBHOOK_URL"
  echo "Webhook notifications received: $WEBHOOK_HITS"
  echo ""
  echo "Alert 1 PromQL: $ERROR_EXPR"
  echo "Alert 2 PromQL: $BURN_EXPR"
  echo ""
  echo "Timeline:"
  echo "  INJECT:  $T_INJECT"
  echo "  FIRE:    ${T_FIRE:-pending}"
  echo "  DIAG:    $T_DIAG"
  echo "  FIX:     $T_FIX"
  echo "  RESOLVED: $T_RESOLVED"
  echo ""
  echo "=== argocd N/A — use Grafana Alerting UI ==="
  grafana_api "$GRAFANA_URL/api/prometheus/grafana/api/v1/rules" | python3 -m json.tool 2>/dev/null | head -40 || true
  echo ""
  curl -sf "http://localhost:9090/api/v1/query?query=sum(rate(gateway_requests_total{status=~\"5..\"}[5m]))/sum(rate(gateway_requests_total[5m]))*100" | python3 -m json.tool | head -15
} | tee "$OUT"

echo "Proofs saved to $OUT"
echo "Grafana: $GRAFANA_URL (admin/admin)"
echo "Webhook: $WEBHOOK_URL"

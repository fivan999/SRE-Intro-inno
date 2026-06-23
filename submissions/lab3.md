# Lab 3 Submission — Monitoring, Observability & SLOs

> **Note:** All commands use **Podman** instead of Docker:
> ```bash
> cd app/
> alias dc='podman compose -f docker-compose.yaml -f ../docker-compose.monitoring.yaml'
> ```

---

## Task 1 — Configure Monitoring & Build Dashboard

### 3.1: Write the Prometheus configuration

Created `monitoring/prometheus/prometheus.yml`:

```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s

rule_files:
  - "rules.yml"

scrape_configs:
  - job_name: gateway
    static_configs:
      - targets: ["gateway:8080"]

  - job_name: events
    static_configs:
      - targets: ["events:8081"]

  - job_name: payments
    static_configs:
      - targets: ["payments:8082"]
```

Internal ports (8080/8081/8082), Compose service names as hostnames.

### 3.2: Start the monitoring stack

```bash
cd app/
podman compose -f docker-compose.yaml -f ../docker-compose.monitoring.yaml up -d --build
```

**Output of `compose ps` (7 services):**

```text
CONTAINER ID  IMAGE                                 COMMAND               STATUS                  PORTS                   NAMES
bf2480e6da1a  localhost/app_payments:latest         uvicorn main:app ...  Up                      0.0.0.0:8082->8082/tcp  app_payments_1
9561d4a5d8ef  docker.io/library/postgres:17-alpine  postgres              Up (healthy)            0.0.0.0:5432->5432/tcp  app_postgres_1
1e602029dd7d  docker.io/library/redis:7-alpine      redis-server          Up (healthy)            0.0.0.0:6379->6379/tcp  app_redis_1
6f5ff4510bc7  docker.io/prom/prometheus:v3.11.2     --config.file=...     Up                      0.0.0.0:9090->9090/tcp  app_prometheus_1
10d01b71f4ee  docker.io/grafana/grafana:13.0.1                            Up                      0.0.0.0:3000->3000/tcp  app_grafana_1
e6ab39b2cf0a  localhost/app_events:latest           uvicorn main:app ...  Up                      0.0.0.0:8081->8081/tcp  app_events_1
6d97a84d373a  localhost/app_gateway:latest          uvicorn main:app ...  Up                      0.0.0.0:3080->8080/tcp  app_gateway_1
```

### 3.3: Verify Prometheus is scraping

```text
events       up       http://events:8081/metrics
gateway      up       http://gateway:8080/metrics
payments     up       http://payments:8082/metrics
```

All three targets show `up`.

### 3.4: Explore metrics

**Raw metrics from gateway:**

```text
gateway_requests_total{method="GET",path="/events",status="200"} 138.0
gateway_requests_total{method="POST",path="/events/{id}/reserve",status="200"} 63.0
gateway_requests_total{method="POST",path="/reserve/{id}/pay",status="200"} 23.0
gateway_requests_total{method="POST",path="/events/{id}/reserve",status="409"} 5.0
gateway_request_duration_seconds_bucket{le="0.005",method="GET",path="/events"} 31.0
gateway_request_duration_seconds_bucket{le="0.01",method="GET",path="/events"} 137.0
```

**Custom metrics in Prometheus:**

```text
events_db_pool_size
events_orders_total
events_request_duration_seconds_bucket
events_request_duration_seconds_count
events_request_duration_seconds_sum
events_requests_total
events_reservations_active
gateway_request_duration_seconds_bucket
gateway_request_duration_seconds_count
gateway_request_duration_seconds_sum
gateway_requests_total
payments_charges_total
payments_request_duration_seconds_bucket
payments_request_duration_seconds_count
payments_request_duration_seconds_sum
payments_requests_total
```

**Request rate (Traffic golden signal):**

```text
Request rate: 0.24 req/s
```

PromQL: `sum(rate(gateway_requests_total[5m]))`

### 3.5: Complete the golden signals dashboard

Replaced placeholder panels in `monitoring/grafana/dashboards/golden-signals.json`.

**Latency panel (Time series, unit: seconds):**

```promql
histogram_quantile(0.50, sum(rate(gateway_request_duration_seconds_bucket[1m])) by (le))
histogram_quantile(0.95, sum(rate(gateway_request_duration_seconds_bucket[1m])) by (le))
histogram_quantile(0.99, sum(rate(gateway_request_duration_seconds_bucket[1m])) by (le))
```

**Saturation panel (Gauge, min 0, max 10):**

```promql
events_db_pool_size
```

Thresholds: green default, yellow at 7, red at 9.

### 3.6: Inject failure and observe

```bash
./loadgen/run.sh 5 45 &
sleep 12
podman compose -f docker-compose.yaml -f ../docker-compose.monitoring.yaml stop payments
# watched dashboard ~45s, then:
podman compose -f docker-compose.yaml -f ../docker-compose.monitoring.yaml start payments
```

**Normal traffic:**
- Request Rate: steady ~5 req/s
- Error Rate: ~0%
- Service Health: all `up = 1`
- Latency: p50 ~5ms, p99 ~50ms
- Saturation: DB pool 1–2 connections

**After killing payments:**
- Service Health: `up{job="payments"} = 0` within ~15s
- Error Rate: climbed to 3–22% (503 on `/pay`)
- Request Rate: unchanged
- Latency: p99 spiked on pay path
- Saturation: unchanged

Load generator during failure:

```text
[30s] requests=129 success=101 fail=28 error_rate=21.7%
```

### 3.7: Proof of work

1. **Compose ps (7 services)** — see §3.2
2. **Prometheus targets (all 3 up)** — see §3.3
3. **Custom metrics list** — see §3.4
4. **PromQL request rate output** — see §3.4 (`0.24 req/s`)
5. **PromQL for Latency and Saturation panels** — see §3.5
6. **Dashboard observations (normal vs failure)** — see §3.6
7. **Which golden signal showed the failure first? How long after killing payments?**

   **Service Health** (`up` metric) detected the failure first — within **~15 seconds** (one scrape interval) after `stop payments`. `up{job="payments"}` went from 1 to 0 on the next Prometheus scrape.

   **Error Rate** was second — rose **~15–30 seconds** after the kill, once pay requests started returning 503. Request Rate and Saturation did not indicate the failure.

---

## Task 2 — Define SLOs & Recording Rules

### 3.8: Define SLIs and SLOs

**SLI 1 — Availability:** % of gateway requests returning non-5xx

- SLO target: **99.5%** over a 7-day window
- Error budget: 0.5% of total requests
- Math: ~1000 req/day × 7 days = **7000 req/week** → **35 failed requests/week** allowed

**SLI 2 — Latency:** % of gateway requests completing under 500ms

- SLO target: **95%**
- Math: 7000 req/week × 5% = **350 slow requests/week** allowed (>500ms)

**Burn rate:** `(1 - availability) / (1 - 0.995)` — values >1 mean burning error budget too fast.

### 3.9: Create recording rules

Created `monitoring/prometheus/rules.yml`, mounted in `docker-compose.monitoring.yaml`, referenced via `rule_files` in prometheus.yml.

```yaml
groups:
  - name: slo_rules
    interval: 30s
    rules:
      - record: gateway:sli_availability:ratio_rate5m
        expr: |
          sum(rate(gateway_requests_total{status!~"5.."}[5m]))
          /
          sum(rate(gateway_requests_total[5m]))

      - record: gateway:sli_latency_500ms:ratio_rate5m
        expr: |
          sum(rate(gateway_request_duration_seconds_bucket{le="0.5"}[5m]))
          /
          sum(rate(gateway_request_duration_seconds_count[5m]))

      - record: gateway:error_budget_burn_rate:ratio_rate5m
        expr: |
          (1 - gateway:sli_availability:ratio_rate5m)
          /
          (1 - 0.995)
```

**Rules loaded:**

```text
gateway:sli_availability:ratio_rate5m         = ok
gateway:sli_latency_500ms:ratio_rate5m        = ok
gateway:error_budget_burn_rate:ratio_rate5m   = ok
```

### 3.10: Build SLO panel

Added Gauge panel to dashboard:

```promql
gateway:sli_availability:ratio_rate5m * 100
```

Min 99, max 100, threshold at 99.5%.

**SLO gauge during payments failure (1 min):** gauge begins to drop as 503 errors enter the 5-minute rate window. With a brief outage, the drop is small because most of the window still contains healthy traffic. Prometheus during failure: `payments up: 0`, `Error rate: 3.29%`. Sustained outage would push availability below 99.5%.

---

## Bonus Task — Correlate Failure Across Metrics & Logs

1. Started traffic: `./loadgen/run.sh 5 45 &`
2. After 12s: `podman compose stop payments`
3. Watched Grafana ~45s
4. Checked logs: `podman compose logs -t gateway payments`
5. Correlated metrics spike with log timestamps

**Timeline:**

| Time | Event |
|------|-------|
| T+0s | Load generator at 5 RPS |
| T+12s | `podman compose stop payments` — failure injected |
| T+15s | Dashboard: `up{job="payments"} = 0` — **first metric signal** |
| T+20s | Gateway logs: `503 Service Unavailable` on `/pay` — **first error in logs** |
| T+20–30s | Dashboard: Error Rate panel rises |
| T+30s | Load generator: `error_rate=21.7%` |
| T+45s | `podman compose start payments` — recovery |

**Log excerpts:**

```text
# gateway
INFO: 192.168.127.1 - "POST /reserve/{id}/pay HTTP/1.1" 503 Service Unavailable
{"service":"gateway","msg":"payments unreachable for reservation ..."}

# payments — container stopped, no new logs until restart
```

**Root cause:** Payments container stopped. Gateway `/pay` calls `http://payments:8082/charge` → ConnectError → 503 `payments_unavailable`. Metrics: `up{job="payments"}=0` first, then error rate rises. Logs confirm 503 responses at the same time as the dashboard spike.

---

## Files Changed

- `monitoring/prometheus/prometheus.yml`
- `monitoring/prometheus/rules.yml`
- `docker-compose.monitoring.yaml`
- `monitoring/grafana/dashboards/golden-signals.json`

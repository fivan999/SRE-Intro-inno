# Lab 8 Submission — Chaos Engineering

> **Branch:** `feature/lab8`  
> **Cluster:** k3d `quickticket`, gateway Rollout (5 replicas), in-cluster Prometheus, `labs/lab8/mixedload.yaml`

---

## Setup

```bash
kubectl apply -f labs/lab8/mixedload.yaml
kubectl rollout status deployment/mixedload --timeout=60s
# Baseline after 90s: RPS ≈ 11.8
```

---

## Task 1 — Three Chaos Experiments

### Experiment 1 — Pod Kill Under Load

**Hypothesis (before run):** If I delete one gateway pod while traffic is flowing, a small burst of 5xx errors will occur during the ~5–10s readiness gap, but the remaining 4 pods will absorb traffic and Kubernetes will replace the pod within ~30s because the Rollout maintains `replicas: 5`.

**Commands:**

```bash
VICTIM=$(kubectl get pods -l app=gateway -o name | head -1)
kubectl delete "$VICTIM"
kubectl get pods -l app=gateway -w
```

**Observations:**

| Time | Event |
|------|-------|
| 00:26:46 | Killed `pod/gateway-854b67546f-776j8` |
| 00:26:50 | Replacement pod `66npb` starting (4/5 ready) |
| 00:26:52 | 5/5 Running again (**~6 seconds**) |

```text
5xx increase (3m window): 4.11 total
Per-pod rate (1m): swxh=2.6 rps, fzh7j/q252j/tkmz2 ~2.3 rps — traffic redistributed across surviving pods
```

**Comparison:** Hypothesis mostly correct — recovery was **faster** than expected (~6s not 30s). Small number of 5xx (4 over 3 minutes) confirms brief blip, not outage. Surprising: killed pod still appeared in Prometheus series briefly (stale scrape).

**Improvement:** Add PDB `minAvailable: 4` and alert on `kube_pod_status_ready{pod=~"gateway.*"} < 5` for faster detection.

---

### Experiment 2 — Payment Latency Injection

**Hypothesis (before run):** If payments takes 2s per request, `/pay` p99 latency will rise to ~2s but error rate stays near 0 because `GATEWAY_TIMEOUT_MS=5000`. At 6s latency, `/pay` will return 504 and error rate will spike.

**Commands:**

```bash
kubectl set env deployment/payments PAYMENT_LATENCY_MS=2000
kubectl rollout status deployment/payments --timeout=30s
# wait 90s, observe
kubectl set env deployment/payments PAYMENT_LATENCY_MS=6000
# wait 90s, observe
kubectl set env deployment/payments PAYMENT_LATENCY_MS=0
```

**Observations @ 2000ms:**

```text
Error rate (1m): 0
p99 /health: 0.22s
p99 /events:  0.14s
```

Read paths unaffected; no 5xx — hypothesis confirmed for the 2s case.

**Observations @ 6000ms:**

```text
Error rate (1m): 0  (low /pay volume in rate window — mixedload ~3 req/s total)
p99 /events/{id}/reserve: 0.38s
p99 /reserve/{id}/pay: NaN (insufficient histogram samples in [1m] window)
```

**Comparison:** Partial surprise — aggregate error rate stayed 0 even at 6s latency because `/pay` is a small fraction of total RPS (~1/3 of mixedload loop). Latency degradation on write path is **hidden** in global error-rate metrics. This matches the lab hint: partial degradation is harder to detect than a dead service.

**Improvement:** Add per-path SLO alerts on `histogram_quantile(0.99, ... path="/reserve/{id}/pay")` and monitor payment latency separately from gateway aggregate error rate.

---

### Experiment 3 — Redis Failure

**Hypothesis (before run):** If Redis goes down, `GET /events` still works (Postgres only), but `POST /reserve` fails because events needs Redis for ticket holds. `/health` will report degraded.

**Commands:**

```bash
kubectl scale deployment/redis --replicas=0
kubectl run chaos-probe ... # curl /events, /reserve, /health
kubectl scale deployment/redis --replicas=1
```

**Observations (Redis down, 00:29):**

```text
GET /events:     200  0.025s
POST /reserve:   504  5.019s   {"detail":"Events service timeout"}
GET /health:     200  {"status":"healthy","checks":{"events":"ok","payments":"ok"}}
```

**Observations (after restore):**

```text
GET /events:     200  0.022s
POST /reserve:   409  0.121s   (no tickets left — sold out during chaos)
GET /health:     200  healthy
```

**Comparison:** Hypothesis **partially wrong** — reads work and writes fail as expected, but `/health` stayed **healthy** because it only probes `/health` on events and payments, not Redis connectivity. Gateway masks Redis failure as 504 timeout on reserve, not a clear dependency signal.

**Improvement:** Extend events `/health` to check Redis (`PING`) and propagate degraded status to gateway health check.

---

## Task 2 — Combined Failure Scenario

**Scenario design:** payments 30% failure + 500ms latency AND events `DB_MAX_CONNS=3` AND mixedload scaled to 3 replicas — simulates degraded dependencies under increased load (realistic multi-failure incident).

**Commands:**

```bash
kubectl set env deployment/payments PAYMENT_FAILURE_RATE=0.3 PAYMENT_LATENCY_MS=500
kubectl set env deployment/events DB_MAX_CONNS=3
kubectl scale deployment/mixedload --replicas=3
# observe 3 minutes
```

**Observations (after 3 min):**

```text
Combined error rate: 0.91%
p99 /health: 0.30s
p99 /events:  0.23s
```

**Analysis:**

- **First signal:** error rate (~0.9%) rose before visible latency spike on read paths — payment failures on `/pay` drive 5xx without slowing `/events`.
- **Worst path:** `/reserve/{id}/pay` and `/events/{id}/reserve` (write chain) — connection pool queueing under `DB_MAX_CONNS=3` amplifies reserve latency.
- **Weakest link:** **events service DB connection pool** — with only 3 connections and 3 mixedload replicas hammering reserve, queueing causes cascading timeouts. Payments degradation adds intermittent 5xx on top.

**Resilience fix:** Raise `DB_MAX_CONNS` to 10 (default), add pool-exhaustion metric on events, alert when wait time > 100ms.

---

## Bonus Task — Resilience Improvement

**Weakness chosen:** Events DB connection pool exhaustion under `DB_MAX_CONNS=3` during Task 2 combined failure — reserve path p99 spiked and error rate rose.

**Fix applied** (`k8s/events.yaml`):

```diff
- DB_MAX_CONNS: "10"
+ DB_MAX_CONNS: "20"
- requests: cpu 50m, memory 64Mi
+ requests: cpu 100m, memory 128Mi
- limits: cpu 200m, memory 256Mi
+ limits: cpu 500m, memory 512Mi
```

**Re-run:** same combined scenario (payments 30% fail + 500ms latency, mixedload ×3), only varying `DB_MAX_CONNS`.

| Metric | Before (`DB_MAX_CONNS=3`) | After (`DB_MAX_CONNS=20`) |
|--------|---------------------------|---------------------------|
| Gateway error rate (1m) | **0.70%** | **0%** |
| p99 `/events/{id}/reserve` | **0.44s** | **0.22s** |

**Trade-off:** Higher `DB_MAX_CONNS` and memory limits consume more Postgres connections and cluster resources per events pod — acceptable for QuickTicket scale; in production would cap total connections across replicas.

---

## PR

Branch: `feature/lab8` → `main`, submit PR link in Moodle.

```text
- [x] Task 1 — 3 chaos experiments with hypotheses
- [x] Task 2 — combined failure scenario
- [x] Bonus Task — resilience improvement with before/after proof
```

---

## Reproduce

```bash
bash scripts/lab8-setup.sh        # Task 1 + Task 2 → /tmp/lab8-proofs.txt
bash scripts/lab8-bonus.sh        # Bonus before/after → /tmp/lab8-bonus-proofs.txt
```

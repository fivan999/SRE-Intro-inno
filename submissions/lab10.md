# QuickTicket Reliability Review

> **Branch:** `feature/lab10`  
> **Cluster:** k3d `quickticket`, 5-replica gateway Rollout, Postgres on PVC, in-cluster Locust + Prometheus

---

## 1. SLO Compliance

| SLO | Target | Observed (load-10, healthy) | Status |
|-----|--------|-----------------------------|--------|
| Availability (non-5xx) | ≥ 99.5% | 100% (0/453 failures) | ✅ Pass |
| Latency p99 `/events` | < 500 ms | 290 ms | ✅ Pass |
| Error budget burn | < 6× over 30m | Not breached under normal load | ✅ Pass |

At **50+ concurrent users** the system violates both availability and latency SLOs (11%+ 5xx, p99 > 2s).

---

## 2. Load Test Results

Locust ran **in-cluster** (`http://gateway:8080`) with Redis `FLUSHDB` between runs.  
At 50u+ the system fails with 5xx/timeouts before inventory 409s appear in Locust error reports (409 column = 0).

| Users | Ramp | RPS | p50 | p95 | p99 | 5xx error rate | 409 (inventory) |
|------:|-----:|----:|----:|----:|----:|---------------:|----------------:|
| 10 | 2/s | 7.6 | 23 ms | 140 ms | 310 ms | 0% | 0 |
| 50 | 5/s | 23.3 | 690 ms | 1.7 s | 2.3 s | **11.4%** | 0 |
| 100 | 10/s | 25.1 | 1.8 s | 6.2 s | 9.7 s | 28.2% | 0 |
| 200 | 20/s | 18.8 | 4.1 s | 12 s | 24 s | 66.6% | 0 |

**Breaking point:** **50 users (~23 RPS)** — first level where 5xx exceeded 0.5% and aggregated p99 exceeded 500 ms. Gateway timeouts (504) and events 500s dominate.

---

## 3. DORA Metrics

| Metric | Our project | Elite target | Source |
|--------|-------------|--------------|--------|
| Deployment frequency | ~8 production image updates (Labs 5–8 PR merges) | On demand | `git log main`, CI tag commits |
| Lead time for changes | ~5–6 min (CI build 2–3 min + ArgoCD poll ~3 min) | < 1 day | Lab 5 timing, GitHub Actions |
| Change failure rate | ~20% (1 aborted canary / ~5 rollouts in Lab 7) | 0–15% | `kubectl get analysisrun` history |
| Time to restore | Canary auto-abort ~30–60 s; git revert + ArgoCD ~3–5 min | < 1 hour | Lab 7 bonus + Lab 5 |

Solo-student cadence is slower than elite platform teams but recovery is fast thanks to automated canary analysis.

---

## 4. Top 3 Reliability Risks

1. **Single events replica (DB-bound)** — Under 50+ users, events CPU hits 105m while gateway stays at ~40m. Reserve/checkout paths queue behind one connection pool. **Fix:** HPA on events (CPU 70%), raise `DB_MAX_CONNS`, add read replica for `/events` list.

2. **Ephemeral Postgres before Lab 9 PVC** — Pod restart wiped all data; RTO depended on manual `pg_restore`. **Fix:** PVC (done in Lab 9) + CronJob backups every 5 min.

3. **No latency SLO alerts** — Lab 6 alerted on error rate only; Lab 8 payment latency injection caused slow-but-successful responses with zero pages. **Fix:** Add `histogram_quantile(0.99, …)` alert on gateway latency.

---

## 5. Toil Identification

| Toil | How often | Automate with | Time saved |
|------|-----------|---------------|------------|
| `kubectl exec … < seed.sql` after Postgres restart | Every lab session before PVC (~8×) | Init Job or Helm hook on postgres deploy | ~3 min/incident |
| `kubectl port-forward` for Alembic | Every migration run (~4×) | In-cluster Alembic Job + K8s Secret for DB URL | ~2 min/run |
| Manual `kubectl argo rollouts get rollout --watch` | Every canary test (~6×) | AnalysisTemplate auto-promote/abort (Lab 7 bonus) | ~5 min/deploy |

---

## 6. Monitoring Gaps

- **Lab 8 chaos:** wished for `histogram_quantile` on `/pay` and `process_open_fds` on events — latency rose to 2s+ with zero error-rate alert.
- **Lab 9 DR:** no alert on `kube_pod_status_ready{pod=~"postgres.*"} == 0` — outage discovered via mixedload 5xx, not a dedicated DB alert.
- **Missing alert:** Postgres connection pool saturation (`db_pool_in_use / db_pool_max`) would have caught events 500s during load-50 before user-visible 11% error rate.

---

## 7. Capacity Plan

**Current ceiling:** ~**23 RPS** at 50 concurrent users (breaking point).

**Per-pod CPU at breaking point (`kubectl top pods`, sampled after load-50 while cluster still warm):**

```text
gateway (5 pods): 34–59m CPU  (limit 200m) — headroom
events (1 pod):   105m CPU    (limit 200m) — bottleneck
payments (1 pod): 15m CPU     (limit 200m) — idle
```

### For 2× traffic (~46 RPS)

| Component | Current | Proposed | Rationale |
|-----------|---------|----------|-----------|
| gateway | 5 × 200m CPU | 5 × 200m (no change) | 20–30% utilization at breaking point |
| events | 1 × 200m | **3 × 300m** | CPU-saturated; scale horizontally + pool per pod |
| payments | 1 × 200m | 2 × 200m | Headroom for checkout spike |
| Redis | 1 pod | 1 pod (OK) | Holds only short reservation TTLs |
| Postgres | 1 pod, 20 conns | 1 pod + **PgBouncer** | Connection multiplexing for 3 events pods |

**Rough cost** (@ $5/pod/mo): +2 events +1 payments +1 PgBouncer sidecar ≈ **$15–20/mo** incremental.

---

## Task 2 — Detailed Capacity Numbers

See §7 above. Events is the scale target; gateway and payments have spare CPU at the measured breaking point.

---

## Bonus — SRE Handbook

See [`submissions/runbooks/quickticket-handbook.md`](runbooks/quickticket-handbook.md).

---

## PR Checklist

```text
- [x] Task 1 done — load tests, DORA, toil, reliability review (all 7 sections)
- [x] Task 2 done — detailed capacity plan with numbers
- [x] Bonus Task done — SRE handbook (Option B)
```

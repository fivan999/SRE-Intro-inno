# QuickTicket SRE Handbook

## Architecture

```text
                    ┌─────────────┐
  Users / Locust ──►│  gateway    │ (Rollout, 5 replicas)
                    │  :8080      │
                    └──────┬──────┘
           ┌───────────────┼───────────────┐
           ▼               ▼               ▼
    ┌────────────┐  ┌────────────┐  ┌────────────┐
    │  events    │  │  payments  │  │  /health   │
    │  :8081     │  │  :8082     │  │  aggregate │
    └─────┬──────┘  └────────────┘  └────────────┘
          │
    ┌─────┴─────┐
    ▼           ▼
┌────────┐  ┌────────┐
│Postgres│  │ Redis  │  (reservation holds, TTL)
│  PVC   │  │        │
└────────┘  └────────┘
```

- **GitOps:** GitHub → Actions (build/push GHCR) → ArgoCD syncs `k8s/` to k3d.
- **Deploys:** Gateway uses Argo Rollouts canary (20% → analysis → 100%).
- **Observability:** Prometheus in `monitoring` namespace scrapes gateway `/metrics`.

---

## How to Deploy

1. Merge PR to `main` with updated image tag in `k8s/gateway.yaml` (or let CI bot commit tag).
2. ArgoCD detects drift within ~3 min and syncs.
3. Watch rollout: `kubectl argo rollouts get rollout gateway --watch`
4. Verify: `kubectl run smoke --rm -it --image=curlimages/curl --restart=Never -- curl -s http://gateway:8080/health`

Rollback: `kubectl argo rollouts abort gateway` (instant) or `git revert` + wait for ArgoCD.

---

## Monitoring

| Check | Query / command | When |
|-------|-----------------|------|
| Error rate | `sum(rate(gateway_requests_total{status=~"5.."}[5m])) / sum(rate(gateway_requests_total[5m]))` | Always |
| RPS | `sum(rate(gateway_requests_total[1m]))` | Capacity reviews |
| p99 latency | `histogram_quantile(0.99, sum(rate(gateway_request_duration_seconds_bucket[5m])) by (le))` | SLO review |
| Pod health | `kubectl get pods -l app=gateway` | Incidents |
| Postgres ready | `kubectl get pod -l app=postgres` | After node drain / chaos |

Grafana dashboard: QuickTicket Golden Signals (Lab 3/6).

---

## Incident Response

### High 5xx error rate (from Lab 6 runbook)

1. `curl http://gateway:8080/health` — identify failing dependency.
2. `kubectl logs deploy/events --tail=50` and `deploy/payments --tail=50`.
3. Common fixes:
   - Payments down → `kubectl rollout restart deployment/payments`
   - DB pool exhausted → `kubectl rollout restart deployment/events`, check `DB_MAX_CONNS`
   - Postgres pod crash → check PVC mount; restore from `/backups/` if data lost

**Escalation:** unresolved in 10 min → page on-call / instructor.

### Canary failure

AnalysisRun `Failed` → Rollout auto-aborts. Confirm stable pods: `kubectl argo rollouts get rollout gateway`.

---

## Backup / Restore (Lab 9)

**Automated:** CronJob `postgres-backup` every 5 min → `postgres-backups` PVC (retain 5 dumps).

**Manual backup:**

```bash
kubectl exec deploy/postgres -- pg_dump -U quickticket -Fc quickticket > /tmp/quickticket.dump
```

**Restore:**

```bash
POD=$(kubectl get pod -l app=postgres -o name | cut -d/ -f2)
kubectl cp /tmp/quickticket.dump $POD:/tmp/backup.dump
kubectl exec $POD -- pg_restore -U quickticket -d quickticket --clean --if-exists /tmp/backup.dump
kubectl rollout restart deployment/events
```

**RPO:** ≤ 5 min (CronJob interval). **RTO with PVC:** ~10 s (pod restart). **RTO without PVC:** minutes (manual restore).

---

## Load Testing

```bash
cp labs/lab10/locustfile.py locustfile.py
kubectl create configmap locustfile --from-file=locustfile.py=locustfile.py --dry-run=client -o yaml | kubectl apply -f -
kubectl exec deploy/redis -- redis-cli FLUSHDB
kubectl apply -f labs/lab10/locust-runner.yaml  # edit users/ramp per run
```

Always run Locust **in-cluster**, never via `port-forward`.

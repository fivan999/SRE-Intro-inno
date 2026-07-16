# Lab 12 Submission — Advanced Kubernetes Resilience

> **Branch:** `feature/lab12`  
> **Cluster:** k3d `quickticket`, 5-replica gateway Rollout, 2-replica events/payments/notifications, Postgres PVC  
> **Proofs:** `submissions/lab12-proofs.txt`

---

## Task 1 — Multi-Replica Failover + PDBs

### 12.1 `kubectl get deploy,rollout`

```text
NAME                            READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/events          2/2     2            2           86s
deployment.apps/mixedload       2/2     2            2           40s
deployment.apps/notifications   2/2     2            2           86s
deployment.apps/payments        2/2     2            2           86s
deployment.apps/postgres        1/1     1            1           87s
deployment.apps/redis           1/1     1            1           86s

NAME                          DESIRED   CURRENT   UP-TO-DATE   AVAILABLE   AGE
rollout.argoproj.io/gateway   5         5         5            5           86s
```

### 12.2 Pod kill under mixedload

```text
5xx before: 0
pod "gateway-764d4f9d55-2d65w" deleted
pod "events-5b66c46cf8-bqmpf" deleted
5xx after: 0
```

### 12.3 `kubectl get pdb`

```text
NAME                MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS   AGE
events-pdb          1               N/A               1                     102s
gateway-pdb         2               N/A               3                     102s
notifications-pdb   N/A             1                 1                     102s
payments-pdb        1               N/A               1                     102s
```

### 12.4 Topology spread + placement

```json
[
    {
        "labelSelector": {"matchLabels": {"app": "gateway"}},
        "maxSkew": 1,
        "topologyKey": "kubernetes.io/hostname",
        "whenUnsatisfiable": "ScheduleAnyway"
    }
]
```

```text
NAME                       READY   STATUS    NODE
gateway-764d4f9d55-2z6qq   1/1     Running   k3d-quickticket-server-0
gateway-764d4f9d55-bc9v6   1/1     Running   k3d-quickticket-server-0
gateway-764d4f9d55-ctrmn   1/1     Running   k3d-quickticket-server-0
gateway-764d4f9d55-mlwf9   1/1     Running   k3d-quickticket-server-0
gateway-764d4f9d55-n9w7c   1/1     Running   k3d-quickticket-server-0
```

Single-node k3d: all pods on one NODE — constraint is correct, not observable here.

### 12.5 PDB eviction rejection (HTTP 429)

After `kubectl patch pdb events-pdb --type=merge -p '{"spec":{"minAvailable":2}}'`:

```json
{
    "kind": "Status",
    "apiVersion": "v1",
    "status": "Failure",
    "message": "Cannot evict pod as it would violate the pod's disruption budget.",
    "reason": "TooManyRequests",
    "details": {
        "causes": [
            {
                "reason": "DisruptionBudget",
                "message": "The disruption budget events-pdb needs 2 healthy pods and has 2 currently"
            }
        ]
    },
    "code": 429
}
```

### Answers

**3 replicas + minAvailable:1 → max evictions?** 2 (3 − 1). Our `gateway-pdb` uses `minAvailable:2` with 5 replicas → max 3 simultaneous evictions while keeping 2 live.

**Topology spread on 3 nodes, 5 pods, maxSkew:1?** Placement 2/2/1. For 7 pods: 3/2/2.

---

## Task 2 — Graceful Shutdown + Zero-Downtime Migration

### preStop + readinessProbe (gateway Rollout)

```yaml
terminationGracePeriodSeconds: 40
lifecycle:
  preStop:
    exec:
      command: ["sh", "-c", "sleep 10"]
readinessProbe:
  periodSeconds: 2
  failureThreshold: 1
```

### Rolling restart under load

```text
5xx before restart: 0
rollout 'gateway' restarts → Healthy
5xx after restart: 0
```

### CREATE INDEX CONCURRENTLY

```python
with op.get_context().autocommit_block():
    op.create_index("idx_events_event_date", "events", ["event_date"],
                    postgresql_concurrently=True, if_not_exists=True)
```

```text
5xx before migration: 0
Running upgrade b2c3d4e5f6a7 -> c3d4e5f6a7b8, index events.event_date concurrently
real  0m0.232s
"idx_events_event_date" btree (event_date)
5xx after migration: 0
```

### Expand-and-contract sketch (12.8)

1. **Migration 1:** `ADD COLUMN scheduled_at TIMESTAMPTZ NULL`
2. **Deploy A:** reads `COALESCE(scheduled_at, event_date)`
3. **Migration 2:** `UPDATE … SET scheduled_at = event_date WHERE scheduled_at IS NULL`; `ALTER … NOT NULL`
4. **Deploy B:** read/write `scheduled_at` only
5. **Migration 3:** `DROP COLUMN event_date`

**Why M3 after Deploy B?** Deploy A still references `event_date` in COALESCE — dropping early → 500 on `/events`.

**Why CONCURRENTLY?** Non-concurrent index takes ACCESS EXCLUSIVE for minutes. CONCURRENTLY uses SHARE UPDATE EXCLUSIVE — no blocking reads/writes.

---

## Bonus — Live Expand-and-Contract

| Step | 5xx (1m) |
|------|--------:|
| Baseline | 0 |
| M1 add `scheduled_at` | 0 |
| Deploy A (COALESCE) | 0 |
| M2 backfill + NOT NULL | 0 |
| Deploy B + M3 drop `event_date` | 0 |

Final `\d events`:

```text
 scheduled_at  | timestamp with time zone |           | not null |
Indexes:
    "events_pkey" PRIMARY KEY, btree (id)
```

No `event_date` column remains.

**Dangerous reorder:** Dropping `event_date` before Deploy B fully rolls out → Deploy-A pods still COALESCE against missing column → 500.

**Rollback after Deploy B:** Re-adding `event_date` + backfill is insufficient if Deploy B never writes it — need Deploy A code live again before schema revert.

---

## PR Checklist

```text
- [x] Task 1 — multi-replica + PDB + topology spread + eviction block
- [x] Task 2 — preStop + zero-error restart + CONCURRENTLY + sketch
- [x] Bonus — expand-and-contract executed live
```

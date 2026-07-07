# Lab 9 Submission — Stateful Services & DB Reliability

> **Branch:** `feature/lab9`  
> **Cluster:** k3d `quickticket`, gateway Rollout (5 replicas), mixedload, in-cluster Prometheus

---

## Task 1 — Migrations & Backup/Restore

### 9.1–9.3: Alembic history

```text
a1b2c3d4e5f6 -> b2c3d4e5f6a7 (head), add email column to events
<base> -> a1b2c3d4e5f6, baseline - pre-existing schema
```

Current before upgrade: `a1b2c3d4e5f6` (baseline stamped on existing schema).

### 9.4: Migration under load

```text
5xx before: 0
real    0m0.223s   (alembic upgrade head)
5xx after: 0
```

```text
                                        Table "public.events"
    Column     |           Type           | Collation | Nullable |              Default
---------------+--------------------------+-----------+----------+------------------------------------
 id            | integer                  |           | not null | nextval('events_id_seq'::regclass)
 name          | text                     |           | not null |
 venue         | text                     |           | not null |
 event_date    | timestamp with time zone |           | not null |
 total_tickets | integer                  |           | not null |
 price_cents   | integer                  |           | not null |
 email         | character varying(255)   |           |          |
```

Nullable `email` column added with zero additional 5xx under mixedload traffic.

### 9.5: pg_dump backup

```text
-rw-r--r--  7.1K  /tmp/quickticket.dump
/tmp/quickticket.dump: PostgreSQL custom database dump - v1.16-0

220; 1259 16412 TABLE public alembic_version
218; 1259 16386 TABLE public events
219; 1259 16394 TABLE public orders
```

### 9.6: DROP + restore

| Phase | events | orders |
|-------|-------:|-------:|
| Before disaster | 5 | 50 |
| After DROP TABLE orders | 5 | — (table gone) |
| After pg_restore | 5 | 50 |

**API after restore:** `curl http://gateway:8080/events` → `/events=200`

### 9.7: RPO answer

**RPO of a single manual `pg_dump`:** equal to the time since the last dump. In our run the backup was taken at 14:17:15 UTC and the pod kill at 14:17:17 UTC — **~2 seconds** of write window. Any orders created after the dump would be lost on restore.

**How to improve:** automate periodic backups (Bonus CronJob every 5 min → RPO ≤ 5 min), add WAL archiving / PITR for seconds-level RPO, and mount Postgres on a PVC so a pod restart does not wipe the live dataset.

---

## Task 2 — Disaster Recovery (no PVC)

### 9.8: Timestamps

| Phase | Time |
|-------|------|
| Healthy (T0) | 17:17:17 |
| Disaster (pod kill) | 17:17:17 |
| New pod Ready | 17:17:20 |
| pg_restore complete | 17:17:20 |
| App fully up (events restarted) | 17:17:29 |

**Actual RTO** = T_APP_READY − T_KILL = **12 seconds** (includes `pg_restore` + events rollout restart).

After kill, `\dt` returned **"Did not find any relations"** — ephemeral pod storage was wiped.

### 9.9: RPO gap

| Metric | Value |
|--------|------:|
| Orders before disaster | 50 |
| Orders after restore | 50 |
| Record gap (N − M) | 0 |

Backup was taken seconds before the kill, so no order rows were lost. Prometheus `error_rate` (30s window) peaked at **~0.78 req/s** during the outage.

**Why was the new pod empty?** The ephemeral Postgres Deployment had no `PersistentVolumeClaim` — data lived on the container filesystem and was discarded when the pod was recreated.

**Fix:** mount a PVC on `/var/lib/postgresql/data` (Bonus B.1).

---

## Bonus — PVC + Automated Backup CronJob

### B.1: PVC Postgres diff

```diff
+apiVersion: v1
+kind: PersistentVolumeClaim
+metadata:
+  name: postgres-data
+spec:
+  accessModes: [ReadWriteOnce]
+  resources:
+    requests:
+      storage: 1Gi
 ---
 containers:
+  env:
+    - name: PGDATA
+      value: /var/lib/postgresql/data/pgdata
+  volumeMounts:
+    - name: data
+      mountPath: /var/lib/postgresql/data
+volumes:
+  - name: data
+    persistentVolumeClaim:
+      claimName: postgres-data
```

**Re-run disaster with PVC:**

| Phase | Time |
|-------|------|
| Pod kill | 17:17:51 |
| New pod Ready (data intact) | 17:17:54 |

**RTO with PVC: ~3 seconds** — no `pg_restore` needed; 5 events survived pod restart.

### B.2: CronJob backup (`k8s/backup-cronjob.yaml`)

Committed in PR — key spec: schedule `*/5 * * * *`, `concurrencyPolicy: Forbid`, `postgres:17-alpine`, dumps to `/backups/quickticket_<UTC>.dump`, retention keeps 5 newest via `tail -n +6 | rm`.

**manual-6 / manual-7 rotation logs:**

```text
created /backups/quickticket_20260707T141848Z.dump
removed '/backups/quickticket_20260707T141829Z.dump'
created /backups/quickticket_20260707T141851Z.dump
removed '/backups/quickticket_20260707T141833Z.dump'
```

**After 7 manual runs — exactly 5 files remain:**

```text
quickticket_20260707T141837Z.dump
quickticket_20260707T141841Z.dump
quickticket_20260707T141845Z.dump
quickticket_20260707T141848Z.dump
quickticket_20260707T141851Z.dump
```

---

## PR Checklist

```text
- [x] Task 1 done — Alembic migration under load + pg_dump/pg_restore cycle
- [x] Task 2 done — disaster recovery RTO/RPO measurement
- [x] Bonus Task done — PVC + automated CronJob backup with rotation
```

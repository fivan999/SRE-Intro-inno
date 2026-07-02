# Lab 7 Submission — Progressive Delivery: Canary Deployments

> **Branch:** `feature/lab7`  
> **Cluster:** k3d `quickticket` + Argo Rollouts v1.9.0

---

## Task 1 — Manual Canary Deployment

### 7.1: Argo Rollouts version

```text
kubectl-argo-rollouts: v1.9.0+838d4e7
  BuildDate: 2026-03-20T21:11:48Z
  GitCommit: 838d4e792be666ec11bd0c80331e0c5511b5010e
  Platform: darwin/arm64
```

### 7.2: Gateway converted to Rollout

`k8s/gateway.yaml`: `kind: Rollout`, `replicas: 5`, canary strategy with `setWeight: 20 → pause → 60 → pause 30s → 100`.

### 7.3: Canary paused at 20%

Triggered by changing `APP_VERSION` from `v2` to `v3`:

```text
Name:            gateway
Status:          ॥ Paused
Message:         CanaryPauseStep
Strategy:        Canary
  Step:          1/5
  SetWeight:     20
  ActualWeight:  20
Replicas:
  Desired:       5
  Current:       5
  Updated:       1
  Ready:         5

⟳ gateway                            Rollout     ॥ Paused
├──# revision:2
│  └──⧉ gateway-66b68f8b78           ReplicaSet  ✔ Healthy  canary
│     └──□ gateway-66b68f8b78-rvplg  Pod         ✔ Running
└──# revision:1
   └──⧉ gateway-854b67546f           ReplicaSet  ✔ Healthy  stable
      ├──□ gateway-854b67546f-6c5wm  Pod         ✔ Running
      ├──□ gateway-854b67546f-clgqh  Pod         ✔ Running
      ├──□ gateway-854b67546f-jthfg  Pod         ✔ Running
      └──□ gateway-854b67546f-npntf  Pod         ✔ Running
```

### 7.4: Traffic split verification (in-cluster loadgen)

```text
pod/gateway-66b68f8b78-rvplg  APP_VERSION=v3  events_requests=11   (~20%)
pod/gateway-854b67546f-6c5wm  APP_VERSION=v2  events_requests=14
pod/gateway-854b67546f-clgqh  APP_VERSION=v2  events_requests=9
pod/gateway-854b67546f-jthfg  APP_VERSION=v2  events_requests=18
pod/gateway-854b67546f-npntf  APP_VERSION=v2  events_requests=16
```

Canary pod received ~20% of `/events` traffic (11 of 68 requests in 30s sample) — matches `setWeight: 20`.

### 7.5: Promote to 100%

```bash
kubectl argo rollouts promote gateway
```

```text
Status:          ✔ Healthy
  Step:          5/5
  SetWeight:     100
  ActualWeight:  100
Replicas:
  Updated:       5
```

Progression observed: `Paused@20%` → `Paused@60%` (30s auto-pause) → `Healthy@100%`.

### 7.6: Bad version + abort

Triggered `APP_VERSION=v3-bad`, waited for pause at 20%, then:

```bash
kubectl argo rollouts abort gateway
```

**Before abort** (1 canary pod on bad revision):

```text
Status:          ॥ Paused
  SetWeight:     20
  ActualWeight:  20
Updated:       1
revision:3  gateway-76b9f58f76  canary
revision:2  gateway-66b68f8b78  stable (4 pods)
```

**After abort:**

```text
Status:          ✖ Degraded
Message:         RolloutAborted: Rollout aborted update to revision 3
  SetWeight:     0
  ActualWeight:  0
Updated:       0
revision:3  gateway-76b9f58f76  • ScaledDown  canary
revision:2  gateway-66b68f8b78  stable (4 pods serving)
```

### 7.7: Abort vs git revert (Lab 5)

| Method | Time to stable traffic | Notes |
|--------|------------------------|-------|
| `kubectl argo rollouts abort` | **~1–2 seconds** | Weight → 0 immediately; kube-proxy stops routing to canary. Rollout stays `Degraded` until `retry`. |
| `git revert` + ArgoCD sync (Lab 5) | **~4 seconds** | Requires Git push + ArgoCD reconciliation + pod image pull |

**Answer:** Abort is faster for runtime rollback — traffic shifts off the canary in seconds without waiting for Git/CI/ArgoCD. Git revert is still needed for durable config rollback (source of truth), but Argo Rollouts abort is the right tool for instant traffic protection during a bad canary.

---

## Task 2 — Multi-Step Canary with Observation

### 7.8: Multi-step strategy (designed)

```yaml
strategy:
  canary:
    steps:
      - setWeight: 20
      - pause: {duration: 60s}
      - setWeight: 40
      - pause: {duration: 60s}
      - setWeight: 60
      - pause: {duration: 60s}
      - setWeight: 80
      - pause: {duration: 30s}
      - setWeight: 100
```

### 7.9: Rollout observation (`--watch` during Task 1 promote)

Using `kubectl argo rollouts get rollout gateway --watch` during promote:

| Step | SetWeight | Updated replicas | Observation |
|------|-----------|------------------|-------------|
| 1 | 20% | 1/5 | Paused — manual promote required |
| 2 | 60% | 3/5 | Auto after promote; old stable pods terminating |
| 3 | 100% | 5/5 | Healthy — full rollout complete |

- Request rate stayed steady across steps (loadgen RPS unchanged).
- `Updated` replica count climbed 1 → 3 → 5 as weight increased.
- No error spike during good-version rollout.

**Automated abort threshold:** I would auto-abort at **20%** if 5xx error rate exceeds 5% for 2 consecutive measurement windows. At 20% only 1 pod carries canary traffic — enough signal with loadgen, but blast radius is small. Waiting until 60% means 3 pods on bad code before abort — too much exposure. Error rate alone is insufficient; I'd also watch p99 latency and `up{job="gateway"}` for the canary ReplicaSet hash.

---

## Bonus Task — Automated Canary Analysis

### B.1: In-cluster Prometheus

```text
kubectl apply -f labs/lab7/prometheus.yaml
kubectl -n monitoring rollout status deployment/prometheus --timeout=120s
```

Gateway pods discovered with `rs_hash` label (required for canary-scoped queries):

```text
gateway-854b67546f-5xznc rs= 854b67546f up
gateway-854b67546f-9rkw2 rs= 854b67546f up
gateway-854b67546f-s4kzf rs= 854b67546f up
gateway-854b67546f-hmnwf rs= 854b67546f up
```

### B.2: AnalysisTemplate

```text
$ kubectl get analysistemplate gateway-error-rate
NAME                 AGE
gateway-error-rate   48m
```

Manifest: `k8s/analysis-template.yaml` — queries in-cluster Prometheus for canary 5xx error rate (`rs_hash="{{args.canary-hash}}"`).

### B.3: Rollout strategy with analysis step

```yaml
strategy:
  canary:
    steps:
      - setWeight: 20
      - pause: {duration: 20s}
      - analysis:
          templates:
            - templateName: gateway-error-rate
          args:
            - name: canary-hash
              valueFrom:
                podTemplateHashValue: Latest
      - setWeight: 50
      - pause: {duration: 20s}
      - setWeight: 100
```

> **Note:** DB must be seeded before analysis (`kubectl exec -i deploy/postgres -- psql ... < app/seed.sql`). Without seed data, `/events` returns 500 and good canaries false-abort.

### B.4: Good version — auto-promote

Triggered `APP_VERSION=v4-good` with loadgen running. AnalysisRun `gateway-688b87f449-13-2`:

```text
STATUS: Successful
measurements: [0], [0], [0]   (3 consecutive windows, error rate < 5%)
```

Rollout auto-promoted to 100% without manual `promote`:

```text
Status:          ✔ Healthy
  Step:          6/6
  SetWeight:     100
gateway-688b87f449-13-2      AnalysisRun  ✔ Successful  ✔ 3
```

### B.5: Bad version — auto-abort

Injected `GATEWAY_TIMEOUT_MS=1` (1ms client timeout). `/health` still passes (uses separate 2s timeout), but `/events` returns **504** → ~38% canary error rate.

AnalysisRun `gateway-8667459574-14-2`:

```text
STATUS: Failed
measurements: [0.381], [0.385]   (> 5% threshold, failureLimit=1)
Message: Metric "error-rate" assessed Failed due to failed (2) > failureLimit (1)
```

Rollout auto-aborted:

```text
Status:          ✖ Degraded
Message:         RolloutAborted: Rollout aborted update to revision 14
  SetWeight:     0
gateway-8667459574-14-2      AnalysisRun  ✖ Failed  ✖ 2
```

Stable pods (revision 13) continued serving — no manual `abort` needed.

### B.6: Additional metric for canary analysis

**Answer:** Beyond error rate, add **p99 request latency** (`histogram_quantile(0.99, rate(gateway_request_duration_seconds_bucket{rs_hash="..."}[60s]))`) and **success rate on `/reserve` POST** (write-path errors often appear before aggregate 5xx crosses 5%). Latency catches slow regressions; write-path metrics catch partial failures that read-heavy loadgen misses.

---

## PR

Branch: `feature/lab7` → `main`, submit PR link in Moodle.

```text
- [x] Task 1 — Argo Rollouts installed, canary deployed, promoted + aborted
- [x] Task 2 — multi-step canary with rollout observation
- [x] Bonus Task — automated canary analysis with Prometheus
```

---

## Reproduce

```bash
bash scripts/lab7-setup.sh        # Task 1 proofs → /tmp/lab7-proofs.txt
bash scripts/lab7-bonus.sh        # Bonus proofs → /tmp/lab7-bonus-proofs.txt
```

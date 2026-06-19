# Lab 4 Submission — Kubernetes: Deploy QuickTicket to a Cluster

> **Note:** k3d uses Podman via Docker API socket. Images built with `podman build`, imported via `podman save | k3d image import`.
> Image names use `localhost/quickticket-*:v1` prefix (Podman convention) with `imagePullPolicy: Never`.

---

## Task 1 — Write Manifests & Deploy to k3d

### 4.1: Create a k3d cluster

```bash
k3d cluster create quickticket
kubectl get nodes
```

```text
NAME                       STATUS   ROLES           AGE   VERSION
k3d-quickticket-server-0   Ready    control-plane   ...   v1.35.5+k3s1
```

### 4.2: Build and import images

```bash
cd app/
podman build -t localhost/quickticket-gateway:v1 ./gateway
podman build -t localhost/quickticket-events:v1 ./events
podman build -t localhost/quickticket-payments:v1 ./payments

podman save -o /tmp/quickticket-images.tar \
  localhost/quickticket-gateway:v1 \
  localhost/quickticket-events:v1 \
  localhost/quickticket-payments:v1
k3d image import /tmp/quickticket-images.tar -c quickticket
```

```text
localhost/quickticket-gateway:v1    173 MB
localhost/quickticket-events:v1   188 MB
localhost/quickticket-payments:v1 171 MB
```

### 4.3: Deploy PostgreSQL and Redis

```bash
kubectl apply -f k8s/postgres.yaml
kubectl apply -f k8s/redis.yaml
kubectl get pods
kubectl get svc
```

Both pods reached `Running`. Services: `postgres:5432`, `redis:6379` (ClusterIP).

### 4.4: Deploy QuickTicket services

```bash
kubectl apply -f k8s/gateway.yaml
kubectl apply -f k8s/events.yaml
kubectl apply -f k8s/payments.yaml
kubectl get pods -w
```

All 3 app pods Running. Each Deployment uses `imagePullPolicy: Never` and correct env vars (see `k8s/*.yaml`).

**`kubectl get pods,svc`:**

```text
NAME                            READY   STATUS    RESTARTS   AGE
pod/events-6d7977cccb-s6qhl     1/1     Running   0          29s
pod/gateway-74d4b4f9b-k4j2d     1/1     Running   0          29s
pod/payments-5c4c5679c5-lql5g   1/1     Running   0          28s
pod/postgres-599c58465c-pk5kl   1/1     Running   0          28s
pod/redis-fbb467988-z5dbz       1/1     Running   0          28s

NAME                 TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)    AGE
service/events       ClusterIP   10.43.72.255    <none>        8081/TCP   29s
service/gateway      ClusterIP   10.43.228.214   <none>        8080/TCP   29s
service/payments     ClusterIP   10.43.247.204   <none>        8082/TCP   28s
service/postgres     ClusterIP   10.43.229.131   <none>        5432/TCP   28s
service/redis        ClusterIP   10.43.10.227    <none>        6379/TCP   28s
```

### 4.5: Initialize the database

```bash
kubectl exec -i $(kubectl get pod -l app=postgres -o jsonpath='{.items[0].metadata.name}') \
  -- psql -U quickticket -d quickticket < app/seed.sql
```

Output: `CREATE TABLE`, `INSERT 0 5`

### 4.6: Verify everything works

```bash
kubectl port-forward svc/gateway 3080:8080 &
curl -s http://localhost:3080/events | python3 -m json.tool
curl -s http://localhost:3080/health | python3 -m json.tool
```

```json
[
    {
        "id": 1,
        "name": "Go Conference 2026",
        "venue": "Main Hall A",
        "date": "2026-09-15T09:00:00+00:00",
        "total_tickets": 100,
        "price_cents": 5000,
        "available": 100
    }
]
```

```json
{
    "status": "healthy",
    "checks": {
        "events": "ok",
        "payments": "ok",
        "circuit_payments": "CLOSED"
    }
}
```

### 4.7: Test K8s self-healing

```bash
kubectl delete pod -l app=gateway
kubectl get pods -l app=gateway -w
```

```text
pod "gateway-74d4b4f9b-k4j2d" deleted
NAME                      READY   STATUS    RESTARTS   AGE
gateway-74d4b4f9b-hnplg   1/1     Running   0          13s
```

New pod `gateway-74d4b4f9b-hnplg` reached `1/1 Running` in **~13 seconds** after deletion.

### 4.8: Proof of work

**1. `kubectl get nodes`**

```text
k3d-quickticket-server-0   Ready   control-plane   v1.35.5+k3s1
```

**2. `kubectl get pods,svc`** — see §4.4 (5 pods Running, 5 services)

**3. `curl localhost:3080/events` via port-forward** — see §4.6 (events list returned)

**4. Pod deletion auto-recovery (`kubectl get pods -w`)** — see §4.7 (Terminating → new pod → Running in ~10s)

**5. Recovery time vs docker-compose:**

K8s recreated the gateway pod in **~13 seconds** with no manual steps. In Lab 1 with docker-compose, stopping a service required `podman compose start <service>` manually. K8s Deployment controller continuously reconciles desired state: delete pod → new pod scheduled → readiness probe passes → Service routes traffic again. Compose only restarts stopped containers (`restart: policy`) but does not recreate pods with fresh identity or guarantee replica count.

---

## Task 2 — Probes & Resource Limits

### 4.9: Add readiness and liveness probes

Probes added to gateway (8080), events (8081), payments (8082), plus exec probes on postgres and redis.

**`kubectl describe pod -l app=gateway | grep -A 5 "Liveness\|Readiness"`:**

```text
    Liveness:   http-get http://:8080/health delay=10s timeout=1s period=10s #success=1 #failure=3
    Readiness:  http-get http://:8080/health delay=0s timeout=1s period=5s #success=1 #failure=2
    Environment:
      EVENTS_URL:          http://events:8081
      PAYMENTS_URL:        http://payments:8082
      GATEWAY_TIMEOUT_MS:  5000
```

### 4.10: Observe readiness probe failure

```bash
kubectl delete pod -l app=redis
kubectl get pods -w
kubectl describe pod -l app=events | grep -A 3 "Readiness"
```

After `kubectl delete pod -l app=redis`, the Redis Deployment recreates the pod in **~3 seconds**. Events caches Redis health for 5s (`_REDIS_CHECK_INTERVAL`), and readiness needs 2 consecutive probe failures (period 5s) — so a single pod delete often keeps events at `1/1 Ready` in `kubectl get pods`.

Probe failures are still visible in `kubectl describe pod -l app=events`:

```text
Warning  Unhealthy  ...  Readiness probe failed: HTTP probe failed with statuscode: 503
Warning  Unhealthy  ...  Liveness probe failed: HTTP probe failed with statuscode: 503
```

To observe sustained readiness failure, scale Redis to zero:

```bash
kubectl scale deployment redis --replicas=0
# wait ~15s for cache expiry + probe failures
kubectl describe pod -l app=events | grep 503
kubectl scale deployment redis --replicas=1
```

With Redis unavailable for >10s, `/health` returns 503 (`redis=down`), readiness fails, and the events pod is removed from Service endpoints until Redis is back.

### 4.11: Add resource limits

All 5 Deployments include:

```yaml
resources:
  requests: { cpu: 50m, memory: 64Mi }
  limits:   { cpu: 200m, memory: 256Mi }
```

**`kubectl describe node k3d-quickticket-server-0 | grep -A 10 "Allocated resources"`:**

```text
Allocated resources:
  Resource           Requests     Limits
  --------           --------     ------
  cpu                450m (6%)    1 (14%)
  memory             460Mi (23%)  1450Mi (74%)
```

*(Verified on live cluster after all 5 Deployments running.)*

### Task 2 summary (required outputs)

- **Probes configured:** see §4.9
- **Readiness failure during Redis deletion:** see §4.10 (`0/1 Ready`, 503 probe failures)
- **Node allocated resources:** see §4.11
- **Liveness vs readiness for DB connectivity:**

  **Readiness failure** → pod removed from Service endpoints, **not restarted**. **Liveness failure** → pod **killed and restarted**.

  For database connectivity, use **readiness** — if Postgres/Redis is down, stop routing traffic to the pod; restarting the app won't fix the database. Using liveness for DB checks causes restart loops during dependency outages.

---

## Manifests (`k8s/`)

| File | Contents |
|------|----------|
| `postgres.yaml` | Deployment + Service, postgres:17-alpine, env vars, probes, resources |
| `redis.yaml` | Deployment + Service, redis:7-alpine, probes, resources |
| `events.yaml` | Deployment + Service, all DB/Redis env vars, HTTP probes, resources |
| `gateway.yaml` | Deployment + Service, EVENTS_URL/PAYMENTS_URL, HTTP probes, resources |
| `payments.yaml` | Deployment + Service, fault injection env vars, HTTP probes, resources |

---

## Bonus Task — Helm Chart

### B.1–B.2: Chart scaffold and templates

Raw manifests converted to `k8s/chart/` with parameterized `values.yaml`.

**`k8s/chart/Chart.yaml`:**

```yaml
apiVersion: v2
name: quickticket
description: QuickTicket SRE learning project
version: 0.1.0
```

**`k8s/chart/values.yaml`:**

```yaml
imagePullPolicy: Never

resources:
  requests: { cpu: 50m, memory: 64Mi }
  limits:   { cpu: 200m, memory: 256Mi }

postgres:
  replicas: 1
  image: postgres:17-alpine
  db: quickticket
  user: quickticket
  password: quickticket

redis:
  replicas: 1
  image: redis:7-alpine

gateway:
  replicas: 1
  image: localhost/quickticket-gateway:v1
  eventsUrl: http://events:8081
  paymentsUrl: http://payments:8082
  timeoutMs: "5000"

events:
  replicas: 1
  image: localhost/quickticket-events:v1
  db:
    host: postgres
    port: "5432"
    name: quickticket
    user: quickticket
    password: quickticket
  dbMaxConns: "10"
  redis:
    host: redis
    port: "6379"
    timeoutMs: "1000"
  reservationTtl: "300"

payments:
  replicas: 1
  image: localhost/quickticket-payments:v1
  failureRate: "0.0"
  latencyMs: "0"
```

Templates in `k8s/chart/templates/`: `postgres.yaml`, `redis.yaml`, `gateway.yaml`, `events.yaml`, `payments.yaml` — hardcoded values replaced with `{{ .Values.* }}`.

### B.3: Install and verify

```bash
kubectl delete -f k8s/postgres.yaml -f k8s/redis.yaml \
  -f k8s/gateway.yaml -f k8s/events.yaml -f k8s/payments.yaml
helm install quickticket k8s/chart/
kubectl get pods
helm list
```

**`helm list`:**

```text
NAME        NAMESPACE  REVISION  STATUS    CHART
quickticket default    1         deployed  quickticket-0.1.0
monitoring  default    1         deployed  kube-prometheus-stack-86.3.2
```

**`kubectl get pods` after Helm install (QuickTicket):**

```text
NAME                        READY   STATUS    RESTARTS   AGE
events-6d7977cccb-5hjd6     1/1     Running   0          74s
gateway-74d4b4f9b-ldbwx     1/1     Running   0          74s
payments-5c4c5679c5-p95b7   1/1     Running   0          74s
postgres-599c58465c-tz4rw   1/1     Running   0          74s
redis-fbb467988-qhw2p       1/1     Running   0          74s
```

DB re-seeded, `curl localhost:3080/health` → healthy after Helm deploy.

### B.4: Monitoring via Helm

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm install monitoring prometheus-community/kube-prometheus-stack \
  --set grafana.adminPassword=admin \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false
```

**Monitoring pods created (6 with `release=monitoring` label):**

```text
alertmanager-monitoring-kube-prometheus-alertmanager-0
monitoring-grafana-6f784bf566-6nbgl
monitoring-kube-prometheus-operator-748cc88c88-w744v
monitoring-kube-state-metrics-6b8f7fb688-rrfgs
monitoring-prometheus-node-exporter-dxn4q
prometheus-monitoring-kube-prometheus-prometheus-0
```

kube-prometheus-stack adds Grafana, Prometheus Operator, Prometheus, Alertmanager, kube-state-metrics, and node-exporter — **6 pods** on a single-node k3d cluster (some pods run multiple containers, e.g. Grafana 3/3, Prometheus 2/2).

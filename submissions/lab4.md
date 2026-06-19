# Lab 4 Submission — Kubernetes: Deploy QuickTicket to a Cluster

> **Note:** k3d uses Podman via Docker API socket (`DOCKER_HOST=unix:///var/run/docker.sock`).
> Images built with `podman build`, imported via `podman save | k3d image import`.

---

## Task 1 — Write Manifests & Deploy to k3d

### 4.1: Create a k3d cluster

```bash
export DOCKER_HOST=unix:///var/run/docker.sock
k3d cluster create quickticket
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
localhost/quickticket-gateway:v1   173 MB
localhost/quickticket-events:v1  188 MB
localhost/quickticket-payments:v1 171 MB
```

Manifests use `imagePullPolicy: Never` and image names `localhost/quickticket-*:v1`.

### 4.3–4.4: Deploy all components

```bash
kubectl apply -f k8s/
```

**`kubectl get pods,svc`:**

```text
NAME                            READY   STATUS    RESTARTS   AGE
pod/events-6d7977cccb-pbdn8     1/1     Running   0          ...
pod/gateway-74d4b4f9b-2w5x2     1/1     Running   0          ...
pod/payments-5c4c5679c5-lhtqx   1/1     Running   0          ...
pod/postgres-599c58465c-k5j96   1/1     Running   0          ...
pod/redis-fbb467988-fwsbm       1/1     Running   0          ...

NAME                 TYPE        CLUSTER-IP      PORT(S)
service/events       ClusterIP   10.43.205.6     8081/TCP
service/gateway      ClusterIP   10.43.130.252   8080/TCP
service/payments     ClusterIP   10.43.57.82     8082/TCP
service/postgres     ClusterIP   10.43.30.118    5432/TCP
service/redis        ClusterIP   10.43.9.160     6379/TCP
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
    },
    ...
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
# Before: gateway-74d4b4f9b-zcmqr
gateway-74d4b4f9b-zcmqr   1/1   Terminating
gateway-74d4b4f9b-2w5x2   0/1   Running     (new pod, 2s)
gateway-74d4b4f9b-2w5x2   1/1   Running     (recovered, ~10s)
```

### 4.8: Proof of work

1. **`kubectl get nodes`** — see §4.1
2. **`kubectl get pods,svc`** — see §4.3–4.4
3. **`curl localhost:3080/events`** — see §4.6
4. **Pod deletion auto-recovery** — see §4.7
5. **Recovery time comparison:**

   K8s recreated the gateway pod in **~10 seconds** automatically — no manual intervention. With docker-compose (Lab 1), killing a container required `docker compose start payments` manually. K8s Deployment controller continuously reconcises desired state: delete a pod → new pod scheduled immediately → readiness probe passes → traffic resumes. Compose has no equivalent self-healing loop unless `restart: always` is set, and even then it only restarts the same container definition, not a fresh pod with new identity.

---

## Task 2 — Probes & Resource Limits

### 4.9: Readiness and liveness probes

Added to gateway, events, and payments Deployments (see `k8s/*.yaml`).

**`kubectl describe pod -l app=gateway`:**

```text
Liveness:   http-get http://:8080/health delay=10s timeout=1s period=10s #failure=3
Readiness:  http-get http://:8080/health delay=0s timeout=1s period=5s #failure=2
```

### 4.10: Readiness probe failure during Redis outage

```bash
kubectl scale deployment redis --replicas=0
kubectl get pods -l app=events
kubectl describe pod -l app=events | tail -10
```

Events pod events showed probe failures:

```text
Warning  Unhealthy  ...  Liveness probe failed: HTTP probe failed with statuscode: 503
Warning  Unhealthy  ...  Readiness probe failed: Get "http://...:8081/health": connection refused
```

When Redis is unavailable, events `/health` returns 503 (degraded). Readiness probe fails → pod removed from Service endpoints. Events service caches Redis status for 5s, so brief outages may not immediately flip Ready status; sustained outage triggers probe failures visible in `kubectl describe`.

After `kubectl scale deployment redis --replicas=1`, events returned to `1/1 Ready`.

### 4.11: Resource limits

Each container has:

```yaml
resources:
  requests:
    cpu: 50m
    memory: 64Mi
  limits:
    cpu: 200m
    memory: 256Mi
```

**`kubectl describe node` — Allocated resources:**

```text
Allocated resources:
  Resource           Requests     Limits
  --------           --------     ------
  cpu                450m (6%)    1 (14%)
  memory             460Mi (23%)  1450Mi (74%)
```

### Answer: liveness vs readiness for DB connectivity

**Readiness failure** removes the pod from Service endpoints — no traffic routed, but the pod is **not restarted**. **Liveness failure** kills and **restarts** the pod.

For database connectivity, use **readiness** — if Postgres/Redis is down, you want to stop sending traffic to the pod, not restart it. Restarting the app won't fix a down database and causes unnecessary churn. We observed liveness firing on 503 during Redis outage; readiness is the correct probe for dependency health.

---

## Manifests committed

- `k8s/postgres.yaml`
- `k8s/redis.yaml`
- `k8s/events.yaml`
- `k8s/gateway.yaml`
- `k8s/payments.yaml`

Each file contains Deployment + Service. Task 2 probes and resource limits included in all app Deployments.

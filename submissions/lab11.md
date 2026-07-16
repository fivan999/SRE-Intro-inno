# Lab 11 Submission — Advanced Microservice Patterns

> **Branch:** `feature/lab11`  
> **Cluster:** k3d `quickticket`, gateway Rollout (5 replicas), mixedload + Prometheus  
> **Proofs:** `submissions/lab11-proofs.txt`

---

## Task 1 — Notifications + Retries

### `app/notifications/main.py` (key bits)

```python
NOTIFY_FAILURE_RATE = float(os.getenv("NOTIFY_FAILURE_RATE", "0.0"))
NOTIFY_LATENCY_MS = int(os.getenv("NOTIFY_LATENCY_MS", "0"))
NOTIFY_TOTAL = Counter("notifications_notify_total", "Notify attempts", ["result"])

@app.post("/notify")
def notify(body: dict = None):
    if NOTIFY_LATENCY_MS > 0:
        time.sleep(NOTIFY_LATENCY_MS / 1000)
    if random.random() < NOTIFY_FAILURE_RATE:
        NOTIFY_TOTAL.labels("failed").inc()
        raise HTTPException(500, "Notification delivery failed")
    NOTIFY_TOTAL.labels("success").inc()
    return {"status": "sent", ...}
```

### `app/notifications/requirements.txt`

```text
fastapi==0.136.0
uvicorn==0.44.0
prometheus-client==0.25.0
```

### `k8s/notifications.yaml`

```yaml
spec:
  replicas: 2
  template:
    spec:
      containers:
        - name: notifications
          image: quickticket-notifications:v1
          imagePullPolicy: Never
          ports:
            - containerPort: 8083
```

### `call_with_retry()` (`app/gateway/main.py`)

```python
async def call_with_retry(func, target: str, max_retries: int = RETRY_MAX):
    base_delay = RETRY_BASE_DELAY_MS / 1000.0
    for attempt in range(max_retries):
        try:
            result = await func()
            if attempt > 0:
                RETRY_TOTAL.labels(target=target, result="succeeded_after_retry").inc()
            return result
        except httpx.HTTPStatusError as e:
            status = e.response.status_code
            if status >= 500 or status in (408, 429):
                if attempt == max_retries - 1:
                    RETRY_TOTAL.labels(target=target, result="exhausted").inc()
                    raise
                RETRY_TOTAL.labels(target=target, result="retried").inc()
                delay = base_delay * (2 ** attempt) + random.uniform(0, base_delay)
                await asyncio.sleep(delay)
            else:
                RETRY_TOTAL.labels(target=target, result="non_retryable").inc()
                raise
        except (httpx.TimeoutException, httpx.ConnectError):
            ...
```

### Test #1 — fire-and-forget

```text
NOTIFY_FAILURE_RATE=0.3, NOTIFY_LATENCY_MS=300
result: ok=30 fail=0
pay p99: path="/reserve/{id}/pay" 0.025s
```

### Test #2 — retries

```text
PAYMENT_FAILURE_RATE=0.3
result: ok=29 fail=1
```

```text
gateway_retry_total:
result="retried",target="payments" 15
result="succeeded_after_retry",target="payments" 9
```

```text
notifications_notify_total{result="success"} 5.0
```

Both `retried` and `succeeded_after_retry` are non-zero — retries fire and recover transient payment failures.

### Design answers

**Why notifications non-blocking?** Checkout must not wait for best-effort email/SMS. User gets 200 from `/pay` once payment + confirm succeed; notification failure is logged only.

**Why `cb.call(retry(...))` not `retry(lambda: cb.call(...))`?** Circuit breaker must see the final outcome of all retries. If retry wraps CB, a tripped circuit (`CircuitOpenError`) gets retried — defeating fast-fail and hammering a known-down dependency.

---

## Task 2 — Circuit Breaker + Rate Limiter

### `CircuitBreaker` + `RateLimiter`

```python
class CircuitBreaker:
    async def call(self, func):
        if self.state == self.OPEN:
            if time.time() - self.opened_at >= self.cooldown:
                self._transition(self.HALF_OPEN)
            else:
                raise CircuitOpenError(f"circuit[{self.name}] OPEN")
        try:
            result = await func()
            self.failures = 0
            self._transition(self.CLOSED)
            return result
        except Exception:
            self.failures += 1
            self.opened_at = time.time()
            if self.state == self.HALF_OPEN or self.failures >= self.threshold:
                self._transition(self.OPEN)
            raise

class RateLimiter:
    def allow(self, key: str) -> bool:
        now = time.time()
        q = self.hits[key]
        cutoff = now - self.window_s
        while q and q[0] < cutoff:
            q.popleft()
        if len(q) >= self.rps:
            return False
        q.append(now)
        return True
```

### CB test (100% payment failure)

```text
500s=24 503s=38
```

### CB recovery (PAYMENT_FAILURE_RATE=0.0 + 35s cooldown)

```text
[1]–[15] all 200
```

```text
gateway_circuit_breaker_transitions_total:
to="OPEN" 5
to="HALF_OPEN" 2
to="CLOSED" 2
```

### Rate limit burst (100 rapid GET /events)

```text
200=45 429=55
HTTP/1.1 429 Too Many Requests
retry-after: 1
```

```text
gateway_rate_limit_rejections_total:
path="/events" 59
```

Per-pod limiter: cluster ceiling ≈ `RATE_LIMIT_RPS × gateway replicas`.

---

## Bonus — Bulkhead

### `Bulkhead.call` + wiring

```python
class Bulkhead:
    async def call(self, func):
        try:
            await asyncio.wait_for(self.semaphore.acquire(), timeout=self.acquire_timeout_s)
        except asyncio.TimeoutError:
            BULKHEAD_REJECTIONS.labels(target=self.name).inc()
            raise BulkheadFullError(f"bulkhead[{self.name}] full")
        BULKHEAD_IN_FLIGHT.labels(target=self.name).inc()
        try:
            return await func()
        finally:
            BULKHEAD_IN_FLIGHT.labels(target=self.name).dec()
            self.semaphore.release()

# pay_reservation composition: bulkhead → CB → retry → call
pay_resp = await payments_bulkhead.call(
    lambda: payments_cb.call(lambda: call_with_retry(_charge, target="payments"))
)
```

### Isolation proof (1 gateway replica, `BULKHEAD_PAYMENTS_MAX=3`, `PAYMENT_LATENCY_MS=3000`)

```text
pay[2] 503
pay[14] 200
pay[10] 200
pay[16] 200
EVENTS: ok=30 slow=0
bulkhead_rejections: target="payments" 1
```

`/events` stayed fast (30/30 under 0.5s) while slow `/pay` hit the bulkhead cap and returned 503.

**Bulkhead vs CB ordering:** Bulkhead gates entry; retries inside count as one occupant. CB fast-fail should not burn a slot during OPEN if bulkhead wraps CB.

**Bulkhead vs rate limiter:** Rate limiter caps inbound RPS per path. Bulkhead isolates a slow downstream so one dependency cannot starve other routes.

---

## PR Checklist

```text
- [x] Task 1 — notifications, fire-and-forget, retry (Tests #1 + #2)
- [x] Task 2 — circuit breaker + rate limiter tested
- [x] Bonus — bulkhead implemented and wired
```

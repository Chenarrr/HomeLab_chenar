# Redis Migration: Bitnami Sentinel → Opstree Operator

**Date:** 2026-05-17  
**Cluster:** vps-k3s (Hetzner Cloud, k3s v1.32.4)  
**Result:** Zero downtime, zero data loss

---

## Why We Migrated

Bitnami Redis Sentinel was deployed as a HelmRelease. It worked, but had one critical bug:

The Bitnami `redis` service at port `6379` load-balances across **all** pods — master and replicas. Redis replicas are read-only. When the app tried to write a cache key and the request landed on a replica, it got:

```
ReplyError: READONLY You can't write against a read only replica.
```

The write failed silently. Cache was broken. The fix was to use **sentinel mode** in the app — sentinel always knows which pod is the current master and routes writes correctly.

But while fixing that, we decided to also migrate from Bitnami (Helm-managed) to **Opstree Redis Operator** (CRD-managed) — cleaner, Kubernetes-native, no Helm dependency for stateful workloads.

---

## Architecture: Before vs After

### Before

```
echovote namespace
├── redis-node-0  (Redis + Sentinel sidecar)  ← sometimes master
├── redis-node-1  (Redis + Sentinel sidecar)  ← sometimes master
├── redis-node-2  (Redis + Sentinel sidecar)  ← replica
└── Service: redis
        ├── :6379  → load-balanced (ALL pods) ← caused READONLY bug
        └── :26379 → sentinel port

App → redis:6379 → random pod → 💥 READONLY on replicas
```

### After

```
echovote-infra namespace
├── echovote-redis-v2-replication-0  (Redis master)
├── echovote-redis-v2-replication-1  (Redis replica)
├── echovote-redis-v2-replication-2  (Redis replica)
├── echovote-redis-v2-sentinel-0     (Sentinel)
├── echovote-redis-v2-sentinel-1     (Sentinel)
└── echovote-redis-v2-sentinel-2     (Sentinel)

Service: echovote-redis-v2-replication-master:6379 → master ONLY
Service: echovote-redis-v2-sentinel:26379          → sentinel

App → sentinel:26379 → "master is replication-0:6379" → writes always hit master ✅
```

---

## Why a Separate Namespace (`echovote-infra`)

Kubernetes automatically injects service env vars into every pod in the same namespace. The Bitnami `redis` service in `echovote` was injecting this into every pod:

```
REDIS_PORT=tcp://10.43.x.x:6379
REDIS_PORT_6379_TCP=tcp://10.43.x.x:6379
```

The Opstree sentinel process reads `REDIS_PORT` on startup and crashes with:

```
panic: strconv.Atoi: parsing "tcp://10.43.x.x:6379": invalid syntax
```

Putting Opstree in a **separate namespace** (`echovote-infra`) means the Bitnami service env vars are never injected there. Clean environment, no collision.

---

## How RedisShake Works

RedisShake is a data migration tool that **impersonates a Redis replica**. The source Redis master has no idea it's talking to a migration tool — it treats RedisShake like a normal replica joining the cluster.

### Phase 1 — Handshake

RedisShake connects to the source master and sends the same commands a real Redis replica sends:

```
PING
REPLCONF listening-port 0
REPLCONF capa eof capa psync2
PSYNC ? -1
```

`PSYNC ? -1` means: *"I have no replication history — send me everything from scratch."*

The master responds:

```
+FULLRESYNC <replication-id> <offset>
<RDB binary data...>
```

### Phase 2 — Full Sync (RDB)

The master streams the entire dataset as an **RDB file** — a binary snapshot of every key, value, TTL, and data type currently in memory.

RedisShake parses this RDB and replays every key as a write command to the target (Opstree master). This is the initial bulk copy — every key that existed in Bitnami gets written to Opstree.

### Phase 3 — Live Sync (AOF stream)

After the RDB is done, the master keeps the connection open and streams every new write in real-time — the same replication stream it sends to real replicas.

Every time the app writes to Bitnami:
```
SET yt:drake26 "{...}"  EX 3600
```

The master forwards that command over the replication connection → RedisShake receives it → replays it to Opstree → both databases are identical within milliseconds.

### What `diff=[0]` Means

RedisShake logs this every 5 seconds:

```
read_count=[3], read_ops=[0.60], write_count=[3], write_ops=[0.60], syncing aof, diff=[0]
```

- `read_count` — keys received from source
- `write_count` — keys written to target
- `diff` — bytes received but not yet applied to target

`diff=[0]` = **the two databases are byte-for-byte identical at that moment.**

### Why Zero Data Loss

RedisShake was running continuously from deployment until after the server had already switched to Opstree. There was never a gap where data could be written to Bitnami but not copied to Opstree.

```
[RedisShake syncing Bitnami → Opstree]─────────────────[RedisShake deleted]
                                              │
                                        server switches
                                        to Opstree here
```

---

## Migration Runbook

### Prerequisites

- Opstree Redis Operator installed (`infrastructure/redis-operator/`)
- Opstree Redis CRDs deployed and all 6 pods running (`redis-v2/`)
- RedisShake configmap and deployment written (not in kustomization — manual only)

### Step 1 — Verify Opstree Is Healthy

```bash
kubectl get pods -n echovote-infra
```

Expected output:
```
echovote-redis-v2-replication-0   1/1   Running   master
echovote-redis-v2-replication-1   1/1   Running   slave
echovote-redis-v2-replication-2   1/1   Running   slave
echovote-redis-v2-sentinel-0      1/1   Running
echovote-redis-v2-sentinel-1      1/1   Running
echovote-redis-v2-sentinel-2      1/1   Running
```

Verify sentinel sees the master:
```bash
kubectl exec -n echovote-infra echovote-redis-v2-sentinel-0 -- \
  redis-cli -p 26379 sentinel masters
```

### Step 2 — Find The Bitnami Master

RedisShake needs to connect directly to the Bitnami master pod (not the sentinel port — sentinels don't support the PSYNC replication protocol).

```bash
kubectl exec -n echovote redis-node-0 -c redis -- \
  redis-cli -p 26379 -a <password> sentinel masters 2>/dev/null | grep -A3 'mymaster'
```

Output shows the current master hostname, e.g.:
```
redis-node-1.redis-headless.echovote.svc.cluster.local
```

Update `redisshake/configmap.yaml` with this address on port `6379`.

### Step 3 — Deploy RedisShake

```bash
kubectl apply -f apps/production/echovote/redisshake/configmap.yaml
kubectl apply -f apps/production/echovote/redisshake/deployment.yaml
```

Watch logs until sync is stable:
```bash
kubectl logs -n echovote-infra -l app=redis-shake -f
```

Wait for:
```
syncing aof, diff=[0]
```

This means full RDB copy is done and live sync is running.

### Step 4 — Verify Data Matches

Compare key counts in both Redis:

```bash
# Bitnami
kubectl exec -n echovote redis-node-0 -c redis -- \
  redis-cli -a <password> DBSIZE

# Opstree
kubectl exec -n echovote-infra echovote-redis-v2-replication-0 -- \
  redis-cli -a <password> DBSIZE
```

Both numbers must match. Optionally use RedisInsight side-by-side to visually confirm keys.

### Step 5 — Cutover

Update server env var in `apps/production/echovote/server/deployment.yaml`:

```yaml
# Change this:
- name: REDIS_SENTINEL_HOSTS
  value: "redis:26379"

# To this:
- name: REDIS_SENTINEL_HOSTS
  value: "echovote-redis-v2-sentinel.echovote-infra.svc.cluster.local:26379"
```

Commit and push. Flux reconciles → Kubernetes rolling update → new pod connects to Opstree sentinel.

Verify:
```bash
kubectl logs -n echovote -l app=echovote-server --tail=20 | grep -i redis
# Expected: Redis connected
```

### Step 6 — Cleanup

Delete RedisShake (no longer needed):
```bash
kubectl delete deployment redis-shake -n echovote-infra
kubectl delete configmap redis-shake-config -n echovote-infra
```

Remove Bitnami from kustomization:
```yaml
# Delete this line from apps/production/echovote/kustomization.yaml:
- infrastructure/redis-sentinel.yaml
```

Commit and push. Flux deletes the Bitnami HelmRelease → Helm uninstalls Redis → `redis-node-0/1/2` pods and PVCs are deleted automatically.

---

## Gotchas We Hit

### 1. RedisShake binary path changed

The `ghcr.io/tair-opensource/redisshake:latest` image has the binary at `/app/redis-shake`, not `/redis-shake`. Running `/redis-shake` gives:

```
/bin/sh: /redis-shake: not found
```

Fix: use `/app/redis-shake` in the command.

### 2. RedisShake needs a writable `/app/data` directory

RedisShake writes logs to `/app/data/` on startup. The container image doesn't create this directory with write permissions for non-root users. Add an `emptyDir` volume:

```yaml
volumeMounts:
  - name: app-data
    mountPath: /app/data
volumes:
  - name: app-data
    emptyDir: {}
```

### 3. Config format changed in v4.x

RedisShake v4 broke the config format. Old format (`[source]` / `[target]`) no longer works. New format:

```toml
# OLD (broken in v4)
[source]
type = "sentinel"
...

[target]
type = "standalone"
...

# NEW (v4+)
[sync_reader]
address = "redis-master:6379"
password = "..."

[redis_writer]
address = "opstree-master:6379"
password = "..."
```

### 4. Cannot connect RedisShake to sentinel port

`PSYNC` and `REPLCONF` are Redis replication commands. Sentinel pods (port 26379) don't speak the replication protocol — only Redis data pods (port 6379) do.

Connecting RedisShake to port 26379 gives:
```
ERR unknown command 'PSYNC'
ERR unknown command 'replconf'
```

Fix: point `sync_reader.address` at the actual master pod on port 6379 (discovered via `sentinel masters` command).

### 5. `REDIS_PORT` env var collision

Opstree sentinel pods crash if `REDIS_PORT` is already set in the environment (Kubernetes injects it from services in the same namespace). Symptom:

```
panic: strconv.Atoi: parsing "tcp://10.43.x.x:6379": invalid syntax
```

Fix: deploy Opstree in a separate namespace that has no Redis service.

---

## Final Cluster State

```
echovote namespace
├── echovote-server    → talks to Opstree sentinel ✅
├── echovote-client    ✅
└── mongo              ✅

echovote-infra namespace
├── echovote-redis-v2-replication-0   master  ✅
├── echovote-redis-v2-replication-1   replica ✅
├── echovote-redis-v2-replication-2   replica ✅
├── echovote-redis-v2-sentinel-0      ✅
├── echovote-redis-v2-sentinel-1      ✅
└── echovote-redis-v2-sentinel-2      ✅

Bitnami Redis → deleted ✅
RedisShake    → deleted ✅
```

# Redis Migration: Bitnami Sentinel to Opstree Operator

**Date:** 2026-05-17  
**Result:** No downtime, no data loss.

## Summary

```text
Problem:
App -> redis:6379 -> Bitnami service -> random pod
Writes sometimes hit replicas and failed with READONLY.

Fix:
App -> Opstree Sentinel:26379 -> current Redis master
```

Actual error:

```text
ReplyError: READONLY You can't write against a read only replica.
```

New Redis runs in `echovote-infra` to avoid the Bitnami service env var collision:

```text
REDIS_PORT=tcp://10.43.x.x:6379
panic: strconv.Atoi: parsing "tcp://10.43.x.x:6379": invalid syntax
```

## Files Touched

```text
apps/production/echovote/redisshake/configmap.yaml
apps/production/echovote/redisshake/deployment.yaml
apps/production/echovote/server/deployment.yaml
apps/production/echovote/kustomization.yaml
```

## Commands

### 1. Check Opstree

```bash
kubectl get pods -n echovote-infra
kubectl exec -n echovote-infra echovote-redis-v2-sentinel-0 -- \
  redis-cli -p 26379 sentinel masters
```

Expected:

```text
echovote-redis-v2-replication-0/1/2   Running
echovote-redis-v2-sentinel-0/1/2      Running
name: mymaster
role-reported: master
num-other-sentinels: 2
```

### 2. Find Bitnami Master

```bash
kubectl exec -n echovote redis-node-0 -c redis -- \
  redis-cli -p 26379 -a <password> sentinel masters 2>/dev/null | grep -A1 'name'
```

Used:

```text
source: redis-node-1.redis-headless.echovote.svc.cluster.local:6379
target: echovote-redis-v2-replication-master.echovote-infra.svc.cluster.local:6379
```

### 3. Run RedisShake

```bash
kubectl apply -f apps/production/echovote/redisshake/configmap.yaml
kubectl apply -f apps/production/echovote/redisshake/deployment.yaml
kubectl logs -n echovote-infra -l app=redis-shake -f
```

Good logs:

```text
Config generated. Starting sync...
[INFO] start syncing
[INFO] start receiving rdb
[INFO] syncing aof
[INFO] read_count=[3], write_count=[3], syncing aof, diff=[0]
```

Cutover only happened after `diff=[0]`.

### 4. Compare Data

```bash
kubectl exec -n echovote redis-node-0 -c redis -- \
  redis-cli -a <pw> DBSIZE

kubectl exec -n echovote-infra echovote-redis-v2-replication-0 -- \
  redis-cli -a <pw> DBSIZE
```

Both counts matched. RedisInsight was used as a second check for keys and values.

### 5. Cut Over App

Changed `apps/production/echovote/server/deployment.yaml`.

From:

```yaml
value: "redis:26379"
```

To:

```yaml
value: "echovote-redis-v2-sentinel.echovote-infra.svc.cluster.local:26379"
```

Pushed:

```bash
git add apps/production/echovote/server/deployment.yaml
git commit -m "fix(echovote): use opstree redis sentinel"
git push origin main
```

Verified:

```bash
kubectl logs -n echovote -l app=echovote-server --tail=30 | grep -i redis
```

Expected:

```text
Redis connected
```

### 6. Delete RedisShake

```bash
kubectl delete deployment redis-shake -n echovote-infra
kubectl delete configmap redis-shake-config -n echovote-infra
```

### 7. Remove Bitnami

Deleted this from `apps/production/echovote/kustomization.yaml`:

```yaml
- infrastructure/redis-sentinel.yaml
```

Pushed:

```bash
git add apps/production/echovote/kustomization.yaml
git commit -m "chore(echovote): remove bitnami redis"
git push origin main
```

Flux removed the Bitnami `HelmRelease`, pods, and PVCs.

Archived manifest:

```text
apps/production/echovote/infrastructure/redis-sentinel.yaml
```

It is not in kustomization, so Flux ignores it.

## Notes

RedisShake source must be Redis `6379`, not Sentinel `26379`.

```text
Wrong: 26379 -> ERR unknown command 'PSYNC'
Right: 6379 on the current master
```

RedisShake v4 config:

```toml
[sync_reader]
address = "redis-node-1.redis-headless.echovote.svc.cluster.local:6379"

[redis_writer]
address = "echovote-redis-v2-replication-master.echovote-infra.svc.cluster.local:6379"
```

Container paths:

```text
/app/redis-shake
/app/data
```

`/app/data` is mounted as `emptyDir` so RedisShake can write temp files.

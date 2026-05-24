#!/bin/bash
# redis-restore.sh — Restore a Redis cluster from an S3 AOF backup
#
# Usage:
#   List backups:  ./redis-restore.sh <namespace> <cluster>
#   Restore:       ./redis-restore.sh <namespace> <cluster> <timestamp>
#
# Examples:
#   ./redis-restore.sh echovote-infra echovote-redis-v2-replication
#   ./redis-restore.sh echovote-infra echovote-redis-v2-replication 2026-05-24T07:35:07Z
#
# Requirements: aws CLI, kubectl, jq — configured and pointing at the right cluster.
set -euo pipefail

S3_BUCKET="chenar-homelab-backups"
S3_REGION="eu-north-1"

NS=${1:?"Usage: $0 <namespace> <cluster-name> [timestamp]"}
CLUSTER=${2:?"Usage: $0 <namespace> <cluster-name> [timestamp]"}
TIMESTAMP=${3:-}

S3_PREFIX="s3://${S3_BUCKET}/redis-backups/${NS}/${CLUSTER}"
MASTER_POD="${CLUSTER}-0"

# ── List mode ─────────────────────────────────────────────────────────────────
if [ -z "$TIMESTAMP" ]; then
  echo "Available backups for $NS/$CLUSTER:"
  echo ""
  aws s3 ls "${S3_PREFIX}/" --region "$S3_REGION" 2>/dev/null \
    | awk '{print $2}' | sed 's|/$||' \
    | while read -r TS; do
        META=$(aws s3 cp "${S3_PREFIX}/${TS}/meta.json" - --region "$S3_REGION" 2>/dev/null || echo '{}')
        KEYS=$(echo "$META" | jq -r '.key_count      // "?"')
        SIZE=$(echo "$META" | jq -r '.aof_size_bytes // "?"')
        printf "  %-35s  keys: %-6s  size: %sB\n" "$TS" "$KEYS" "$SIZE"
      done
  echo ""
  echo "To restore: $0 $NS $CLUSTER <timestamp>"
  exit 0
fi

# ── Restore mode ──────────────────────────────────────────────────────────────

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# 1. Download backup from S3
echo "Downloading backup: $TIMESTAMP"
aws s3 cp "${S3_PREFIX}/${TIMESTAMP}/appendonly.tar.gz" "${TMP_DIR}/appendonly.tar.gz" --region "$S3_REGION"
aws s3 cp "${S3_PREFIX}/${TIMESTAMP}/meta.json"         "${TMP_DIR}/meta.json"         --region "$S3_REGION"

# 2. Extract the AOF directory
tar -xzf "${TMP_DIR}/appendonly.tar.gz" -C "$TMP_DIR"
# Result: $TMP_DIR/appendonlydir/ with manifest + base + incr files

# 3. Show what we're restoring
META=$(cat "${TMP_DIR}/meta.json")
EXPECTED_KEYS=$(echo "$META" | jq -r '.key_count')
AOF_SIZE=$(echo "$META"      | jq -r '.aof_size_bytes')

echo ""
echo "┌─ Backup ────────────────────────────────"
echo "│  Timestamp : $TIMESTAMP"
echo "│  Keys      : $EXPECTED_KEYS"
echo "│  AOF size  : ${AOF_SIZE}B (tar.gz)"
echo "├─ Target ────────────────────────────────"
echo "│  Namespace : $NS"
echo "│  Cluster   : $CLUSTER"
echo "│  Master pod: $MASTER_POD"
echo "└─────────────────────────────────────────"
echo ""

# 4. Confirm
echo "WARNING: This replaces ALL live data in $NS/$CLUSTER with this backup."
printf "Type YES to continue: "
read -r CONFIRM
[ "$CONFIRM" = "YES" ] || { echo "Aborted."; exit 1; }

# 5. Get Redis password
REDIS_PASSWORD=$(kubectl get secret redis-helm-values -n "$NS" \
  -o jsonpath='{.data.password}' | base64 -d)

# 6. Stop AOF writes so Redis isn't writing while we replace the files
echo ""
echo "Pausing AOF on master..."
kubectl exec "$MASTER_POD" -n "$NS" -- \
  redis-cli -a "$REDIS_PASSWORD" --no-auth-warning CONFIG SET appendonly no

# 7. Replace the appendonlydir in the master pod with the backup
# Redis 7+ multi-part AOF lives in /data/appendonlydir/
echo "Replacing /data/appendonlydir with backup..."
kubectl exec "$MASTER_POD" -n "$NS" -- rm -rf /data/appendonlydir
kubectl cp "${TMP_DIR}/appendonlydir" "${NS}/${MASTER_POD}:/data/appendonlydir"

# 8. Restart the pod — Redis replays the AOF files on startup
echo "Restarting master pod..."
kubectl delete pod "$MASTER_POD" -n "$NS"
kubectl wait "pod/$MASTER_POD" --for=condition=Ready -n "$NS" --timeout=120s

# 9. Wait for replicas to resync from master
echo "Waiting 10s for replicas to resync..."
sleep 10

# 10. Verify key count
echo "Verifying..."
ACTUAL_KEYS=$(kubectl exec "$MASTER_POD" -n "$NS" -- \
  redis-cli -a "$REDIS_PASSWORD" --no-auth-warning DBSIZE 2>/dev/null \
  | tr -d '[:space:]')

echo ""
echo "=== Restore complete ==="
echo "  Expected keys : $EXPECTED_KEYS"
echo "  Actual keys   : $ACTUAL_KEYS"

if [ "$ACTUAL_KEYS" = "$EXPECTED_KEYS" ]; then
  echo "  Status        : OK — counts match"
else
  echo "  Status        : MISMATCH — normal if some keys had TTLs and expired"
fi

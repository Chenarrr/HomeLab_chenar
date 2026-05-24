#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# redis-restore.sh — Restore a Redis cluster from an S3 AOF backup
#
# Usage:
#   List backups:  ./redis-restore.sh <namespace> <cluster>
#   Restore:       ./redis-restore.sh <namespace> <cluster> <timestamp>
#
# Examples:
#   ./redis-restore.sh echovote-infra echovote-redis-v2-replication
#   ./redis-restore.sh echovote-infra echovote-redis-v2-replication 2026-05-24T01:00:00Z
#
# Requirements: aws CLI, kubectl, jq — configured and pointing at the right cluster.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# ─────────────────────────────────────────────
# CONFIG
# ─────────────────────────────────────────────
S3_BUCKET="chenar-homelab-backups"
S3_REGION="eu-north-1"

NS=${1:?"Usage: $0 <namespace> <cluster-name> [timestamp]"}
CLUSTER=${2:?"Usage: $0 <namespace> <cluster-name> [timestamp]"}
TIMESTAMP=${3:-}

S3_PREFIX="s3://${S3_BUCKET}/redis-backups/${NS}/${CLUSTER}"
MASTER_POD="${CLUSTER}-0"

# ─────────────────────────────────────────────
# LIST MODE — no timestamp given
# Prints all available backups with key count + size from meta.json
# ─────────────────────────────────────────────
if [ -z "$TIMESTAMP" ]; then
  echo "Available backups for $NS/$CLUSTER:"
  echo ""

  aws s3 ls "${S3_PREFIX}/" --region "$S3_REGION" 2>/dev/null \
    | awk '{print $2}' \
    | sed 's|/$||' \
    | while read -r TS; do
        META=$(aws s3 cp "${S3_PREFIX}/${TS}/meta.json" - \
                 --region "$S3_REGION" 2>/dev/null || echo '{}')
        KEYS=$(echo "$META" | jq -r '.key_count      // "?"')
        SIZE=$(echo "$META" | jq -r '.aof_size_bytes // "?"')
        printf "  %-35s  keys: %-8s  size: %sB\n" "$TS" "$KEYS" "$SIZE"
      done

  echo ""
  echo "To restore, run:"
  echo "  $0 $NS $CLUSTER <timestamp>"
  exit 0
fi

# ─────────────────────────────────────────────
# RESTORE MODE
# ─────────────────────────────────────────────

# Step 1: download backup from S3 into a temp dir (auto-cleaned on exit)
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

echo "Downloading backup: $TIMESTAMP"
aws s3 cp "${S3_PREFIX}/${TIMESTAMP}/appendonly.aof" "${TMP_DIR}/appendonly.aof" --region "$S3_REGION"
aws s3 cp "${S3_PREFIX}/${TIMESTAMP}/meta.json"      "${TMP_DIR}/meta.json"      --region "$S3_REGION"

# Step 2: show what we're about to restore
META=$(cat "${TMP_DIR}/meta.json")
EXPECTED_KEYS=$(echo "$META" | jq -r '.key_count')
AOF_SIZE=$(echo "$META"      | jq -r '.aof_size_bytes')

echo ""
echo "┌─ Backup ────────────────────────────────"
echo "│  Timestamp : $TIMESTAMP"
echo "│  Keys      : $EXPECTED_KEYS"
echo "│  AOF size  : ${AOF_SIZE}B"
echo "├─ Target ────────────────────────────────"
echo "│  Namespace : $NS"
echo "│  Cluster   : $CLUSTER"
echo "│  Master pod: $MASTER_POD"
echo "└─────────────────────────────────────────"
echo ""

# Step 3: confirm — must type YES to proceed
echo "WARNING: This replaces ALL live data in $NS/$CLUSTER with this snapshot."
printf "Type YES to continue: "
read -r CONFIRM
if [ "$CONFIRM" != "YES" ]; then
  echo "Aborted."
  exit 1
fi

# Step 4: disable AOF temporarily so Redis doesn't write to it while we replace
echo ""
echo "Disabling AOF on master to safely replace the file..."
REDIS_PASSWORD=$(kubectl get secret redis-helm-values -n "$NS" \
  -o jsonpath='{.data.password}' | base64 -d)

kubectl exec "$MASTER_POD" -n "$NS" -- \
  redis-cli -a "$REDIS_PASSWORD" --no-auth-warning CONFIG SET appendonly no

# Step 5: copy the AOF file into the master pod
echo "Copying appendonly.aof → ${MASTER_POD}:/data/appendonly.aof ..."
kubectl cp "${TMP_DIR}/appendonly.aof" "${NS}/${MASTER_POD}:/data/appendonly.aof"

# Step 6: restart master pod so Redis loads the restored AOF on startup
# Opstree StatefulSet recreates the pod automatically after delete.
# Redis loads /data/appendonly.aof on every startup — that's the restore mechanism.
# Replicas then resync from the restored master via PSYNC.
echo "Restarting master pod to load snapshot..."
kubectl delete pod "$MASTER_POD" -n "$NS"
kubectl wait "pod/$MASTER_POD" --for=condition=Ready -n "$NS" --timeout=120s

# Step 7: wait for replicas to resync
echo "Waiting 10s for replicas to resync from master..."
sleep 10

# Step 8: verify key count matches the backup
echo "Verifying..."
ACTUAL_KEYS=$(kubectl exec "$MASTER_POD" -n "$NS" -- \
  redis-cli -a "$REDIS_PASSWORD" --no-auth-warning DBSIZE 2>/dev/null \
  | tr -d '[:space:]')

# ─────────────────────────────────────────────
# RESULT
# ─────────────────────────────────────────────
echo ""
echo "=== Restore complete ==="
echo "  Expected keys : $EXPECTED_KEYS"
echo "  Actual keys   : $ACTUAL_KEYS"

if [ "$ACTUAL_KEYS" = "$EXPECTED_KEYS" ]; then
  echo "  Status        : ✓ OK — counts match"
else
  echo "  Status        : ⚠ MISMATCH — normal if some keys had TTLs and expired"
  echo "                  Verify: kubectl exec $MASTER_POD -n $NS -- redis-cli -a <pw> DBSIZE"
fi

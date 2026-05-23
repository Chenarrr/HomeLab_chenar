#!/bin/bash
# Redis restore from S3 backup.
#
# Usage:
#   List backups:  ./redis-restore.sh <namespace> <cluster>
#   Restore:       ./redis-restore.sh <namespace> <cluster> <timestamp>
#
# Example:
#   ./redis-restore.sh echovote-infra echovote-redis-v2-replication
#   ./redis-restore.sh echovote-infra echovote-redis-v2-replication 2026-05-22T02:00:00Z
#
# Requirements: aws CLI, kubectl, jq — all configured and pointing at the right cluster.

set -euo pipefail

S3_BUCKET="chenar-homelab-backups"
S3_REGION="eu-north-1"

NS=${1:?"Usage: $0 <namespace> <cluster-name> [timestamp]"}
CLUSTER=${2:?"Usage: $0 <namespace> <cluster-name> [timestamp]"}
TIMESTAMP=${3:-}

S3_PREFIX="s3://${S3_BUCKET}/redis-backups/${NS}/${CLUSTER}"

# ── List mode ─────────────────────────────────────────────────────────────────
if [ -z "$TIMESTAMP" ]; then
  echo "Available backups for $NS/$CLUSTER:"
  echo ""
  aws s3 ls "${S3_PREFIX}/" --region "$S3_REGION" 2>/dev/null \
    | awk '{print $2}' | sed 's|/$||' \
    | while read -r TS; do
        META=$(aws s3 cp "${S3_PREFIX}/${TS}/meta.json" - \
          --region "$S3_REGION" 2>/dev/null || echo '{}')
        KEYS=$(echo "$META" | jq -r '.key_count // "?"')
        SIZE=$(echo "$META" | jq -r '.rdb_size_bytes // "?"')
        printf "  %-35s  keys: %-8s  size: %sB\n" "$TS" "$KEYS" "$SIZE"
      done
  echo ""
  echo "Run: $0 $NS $CLUSTER <timestamp>"
  exit 0
fi

# ── Restore mode ──────────────────────────────────────────────────────────────
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

echo "Downloading backup: $TIMESTAMP"
aws s3 cp "${S3_PREFIX}/${TIMESTAMP}/dump.rdb"  "${TMP_DIR}/dump.rdb"  --region "$S3_REGION"
aws s3 cp "${S3_PREFIX}/${TIMESTAMP}/meta.json" "${TMP_DIR}/meta.json" --region "$S3_REGION"

META=$(cat "${TMP_DIR}/meta.json")
EXPECTED_KEYS=$(echo "$META" | jq -r '.key_count')
RDB_SIZE=$(echo "$META" | jq -r '.rdb_size_bytes')

echo ""
echo "Backup details:"
echo "  Timestamp : $TIMESTAMP"
echo "  Keys      : $EXPECTED_KEYS"
echo "  RDB size  : ${RDB_SIZE}B"
echo ""
echo "Target:"
echo "  Namespace : $NS"
echo "  Cluster   : $CLUSTER"
echo "  Master pod: ${CLUSTER}-0"
echo ""

# Confirmation — must type YES exactly
echo "WARNING: This replaces all live data in $NS/$CLUSTER with this snapshot."
printf "Type YES to continue: "
read -r CONFIRM
if [ "$CONFIRM" != "YES" ]; then
  echo "Aborted."
  exit 1
fi

MASTER_POD="${CLUSTER}-0"

echo ""
echo "Copying dump.rdb to ${MASTER_POD}:/data/dump.rdb ..."
kubectl cp "${TMP_DIR}/dump.rdb" "${NS}/${MASTER_POD}:/data/dump.rdb"

# Delete the master pod — Opstree StatefulSet controller recreates it.
# On startup Redis loads /data/dump.rdb automatically, then replicas resync.
echo "Restarting master pod to load restored snapshot..."
kubectl delete pod "$MASTER_POD" -n "$NS"
kubectl wait "pod/$MASTER_POD" --for=condition=Ready -n "$NS" --timeout=120s

echo "Waiting 10s for replicas to sync from restored master..."
sleep 10

# Verify key count
echo "Verifying..."
# Read password from the same secret the backup job uses
REDIS_PASSWORD=$(kubectl get secret redis-helm-values -n "$NS" \
  -o jsonpath='{.data.password}' | base64 -d)

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
  echo "  Status        : MISMATCH — difference is normal if keys have TTLs and some expired"
  echo "                  Check manually: kubectl exec $MASTER_POD -n $NS -- redis-cli -a <pw> DBSIZE"
fi

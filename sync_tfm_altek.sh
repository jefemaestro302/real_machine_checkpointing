#!/bin/bash

REMOTE="altek1.gap.upv.es"
REMOTE_BASE="~/TFM"
LOCAL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==========================================="
echo "  Deploying Environment to $REMOTE "
echo "==========================================="

echo "[1/3] Creating directory structure on remote..."
ssh $REMOTE "mkdir -p $REMOTE_BASE/repositories/real_machine_checkpoint \
    $REMOTE_BASE/repositories/ia_apps \
    $REMOTE_BASE/checkpoints/ia_apps/ST \
    $REMOTE_BASE/checkpoints/ia_apps/SMT \
    $REMOTE_BASE/results/ia_apps/ST \
    $REMOTE_BASE/results/ia_apps/SMT"

echo ""
echo "[2/3] Syncing Checkpoint Tool..."
rsync -avz --progress \
    --exclude '.git/' \
    --exclude '*.ckpt' \
    --exclude 'scratch/' \
    --exclude 'Tailbench/' \
    --exclude 'ml_gem5_benchmarks/' \
    "$LOCAL_DIR/" "$REMOTE:$REMOTE_BASE/repositories/real_machine_checkpoint/"

echo ""
echo "[3/3] Syncing Cleaned ML Suite (ia_apps)..."
rsync -avz --progress \
    --exclude '.git/' \
    "$LOCAL_DIR/ml_gem5_benchmarks/" "$REMOTE:$REMOTE_BASE/repositories/ia_apps/"

echo ""
echo "==========================================="
echo "✅ Sync complete! Everything is deployed."
echo "==========================================="

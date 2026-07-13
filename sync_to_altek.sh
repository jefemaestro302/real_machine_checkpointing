#!/bin/bash

echo "==========================================="
echo "       Syncing Files to altek Remote       "
echo "==========================================="

rsync -avz --progress \
    --exclude '.git/' \
    --exclude 'm5out/' \
    --exclude 'build/' \
    --exclude '*.ckpt' \
    --exclude 'Tailbench/' \
    ./ altek1.gap.upv.es:TFM/repositories/real_machine_checkpoint/

echo ""
echo "[+] Sync complete! All scripts and source files are up to date on altek."

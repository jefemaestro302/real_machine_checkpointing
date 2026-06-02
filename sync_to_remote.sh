#!/bin/bash

echo "==========================================="
echo "       Syncing Files to azha Remote        "
echo "==========================================="

# Sync everything to azha, but exclude heavy files that don't need to be transferred
rsync -avz --progress \
    --exclude '.git/' \
    --exclude 'm5out/' \
    --exclude 'build/' \
    --exclude '*.ckpt' \
    ./ azha:proyectos_personales/checkpoint_maquina_real/real_machine_checkpoint/

echo ""
echo "[+] Sync complete! All scripts and source files are up to date on azha."

#!/bin/bash
# install_on_altek.sh - Deja el cluster con UNA sola instalacion del repo.
#
#   ./install_on_altek.sh [rama]
#
# Se ejecuta desde la maquina local. Clona (o actualiza) el repo en altek en
# ~/TFM/repositories/real_machine_checkpoint y compila alli el loader y
# libckpt.so. A partir de ese momento todo se lanza desde el propio repo:
#
#   ssh altek1.gap.upv.es
#   ~/TFM/repositories/real_machine_checkpointing/launch_scripts/run_mixed.sh ...
#
# Historicamente convivian tres copias (real_machine_checkpointing/, bk/ y
# scripts sueltos en ~/TFM/gem5_scripts) que fueron divergiendo. Esto lo
# sustituye por una sola.
set -eu

REMOTE="${REMOTE:-altek1.gap.upv.es}"
REPO_URL="${REPO_URL:-git@github.com:jefemaestro302/real_machine_checkpointing.git}"
DEST="${DEST:-\$HOME/TFM/repositories/real_machine_checkpointing}"
BRANCH="${1:-master}"

echo "=== Instalando en $REMOTE (rama $BRANCH) ==="
ssh "$REMOTE" bash -s <<REMOTE_SCRIPT
set -eu
DEST="$DEST"
if [ -d "\$DEST/.git" ]; then
    echo "[1/2] Actualizando clon existente en \$DEST"
    cd "\$DEST"
    git fetch --all --prune
    git checkout "$BRANCH"
    git reset --hard "origin/$BRANCH"
else
    echo "[1/2] Clonando en \$DEST"
    mkdir -p "\$(dirname "\$DEST")"
    git clone "$REPO_URL" "\$DEST"
    cd "\$DEST"
    git checkout "$BRANCH"
fi

echo "[2/2] Compilando loader y libckpt.so"
make -C "\$DEST" clean >/dev/null 2>&1 || true
make -C "\$DEST" "\$DEST/build/loader" "\$DEST/build/libckpt.so" 2>&1 | tail -5
ls -la "\$DEST/build/"
REMOTE_SCRIPT

echo ""
echo "=== Instalado. Para lanzar experimentos: ==="
echo "  ssh $REMOTE"
echo "  \$HOME/TFM/repositories/real_machine_checkpointing/launch_scripts/run_mixed.sh <tag> <insts> timing --pmu <ckpt...>"

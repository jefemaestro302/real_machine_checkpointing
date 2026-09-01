#!/bin/bash
# run_st_timing.sh - Bucle rapido de depuracion: TODO en una CPU simple.
#
#   ./run_st_timing.sh <ckpt> [maxinsts] [timing|atomic] [--caches]
#
# Sin O3: la iteracion mas barata para comprobar si un checkpoint restaura.
# Para medir microarquitectura usa run_mixed.sh.
set -u
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"
check_built

CKPT=${1:?falta el checkpoint}
MAXINSTS=${2:-1000000}
CPU=${3:-timing}
EXTRA=${4:-}

TAG="$(basename "$CKPT" .ckpt)_${CPU}_${MAXINSTS}"
OUTDIR="$OUT_BASE/$TAG"
mkdir -p "$OUTDIR"

echo "=================================================="
echo " checkpoint : $CKPT"
echo " cpu        : $CPU   maxinsts: $MAXINSTS $EXTRA"
echo " outdir     : $OUTDIR"
echo "=================================================="

"$GEM5_BIN" --outdir="$OUTDIR" "$REPO/gem5_configs/x86_st_timing.py" \
    --cmd="$LOADER" --options="$CKPT" \
    --cpu="$CPU" --maxinsts="$MAXINSTS" $EXTRA
RC=$?
echo ""
grep -E "^(simInsts|simOps|simSeconds|hostSeconds)" "$OUTDIR/stats.txt" 2>/dev/null
exit $RC

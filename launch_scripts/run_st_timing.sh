#!/bin/bash
# run_st_timing.sh - Bucle rapido de depuracion: TODO en una CPU simple.
#
#   ./run_st_timing.sh <ckpt> [maxinsts] [timing|atomic] [--caches]
#
# Sin O3: la iteracion mas barata para comprobar si un checkpoint restaura.
# Remapeos de rutas para el loader: el <ckpt>.remap que deja
# regenerate_ckpt_noavx.sh --upload, mas LOADER_OPTS="OLD=NEW ..." si hace falta.
# El loader (build/loader o build/loader_pie) lo elige la config segun el ckpt.
# RMC_RESTORE=auto|direct|loader (auto): con direct no se simula el loader,
# gem5 instala el checkpoint y la CPU arranca en el ROI.
# Para medir microarquitectura usa run_mixed.sh.
set -u
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"
check_built

CKPT=${1:?falta el checkpoint}
[ -f "$CKPT" ] || die "no existe el checkpoint $CKPT"
CKPT="$(realpath "$CKPT")"
MAXINSTS=${2:-1000000}
CPU=${3:-timing}
EXTRA=${4:-}

TAG="$(basename "$CKPT" .ckpt)_${CPU}_${MAXINSTS}"
OUTDIR="$OUT_BASE/$TAG"
mkdir -p "$OUTDIR"

echo "=================================================="
echo " checkpoint : $CKPT"
echo " cpu        : $CPU   maxinsts: $MAXINSTS $EXTRA   restaura: ${RMC_RESTORE:-auto}"
echo " outdir     : $OUTDIR"
echo "=================================================="

"$GEM5_BIN" --outdir="$OUTDIR" "$REPO/gem5_configs/x86_st_timing.py" \
    --cmd="$LOADER" --options="$CKPT $(ckpt_remaps "$CKPT")" \
    --restore="${RMC_RESTORE:-auto}" --cpu="$CPU" --maxinsts="$MAXINSTS" $EXTRA
RC=$?
echo ""
grep -E "^(simInsts|simOps|simSeconds|hostSeconds)" "$OUTDIR/stats.txt" 2>/dev/null
exit $RC

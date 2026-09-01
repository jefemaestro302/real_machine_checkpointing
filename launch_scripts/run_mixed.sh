#!/bin/bash
# run_mixed.sh - Restauracion RMC con CPU mixta: carga en CPU simple, ROI en O3.
#
#   ./run_mixed.sh <tag> <maxinsts> <timing|atomic> [--pmu] <ckpt1> [ckpt2 ...]
#
# Un checkpoint  -> single-thread.
# N checkpoints  -> SMT-N multiprogramado sobre un mismo nucleo O3.
#
# Variables de entorno: GEM5_BIN, LOADER, CKPT_DIR, OUT_BASE.
#
# gem5 se ejecuta CON EL CWD EN EL OUTDIR: la instrumentacion PMU del GAP
# escribe los CPU_*_THD_*.csv con rutas relativas, asi que de otro modo
# acabarian tirados en el directorio de ejecucion del benchmark.
set -u
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"
check_built

TAG=${1:?falta el tag}; shift
MAXINSTS=${1:?falta maxinsts}; shift
LOADCPU=${1:?falta load-cpu (timing|atomic)}; shift
PMU=""
if [ "${1:-}" = "--pmu" ]; then PMU="--pmu"; shift; fi
CKPTS="$*"
[ -z "$CKPTS" ] && die "falta al menos un checkpoint"

OUTDIR="$OUT_BASE/$TAG"
mkdir -p "$OUTDIR"
rm -f "$OUTDIR"/CPU_*.csv

echo "=================================================="
echo " tag        : $TAG"
echo " checkpoints: $CKPTS"
echo " carga      : $LOADCPU     ROI: DerivO3CPU + caches L1/L2  $PMU"
echo " maxinsts   : $MAXINSTS (por hilo)"
echo " outdir     : $OUTDIR"
echo "=================================================="

cd "$OUTDIR"
"$GEM5_BIN" --outdir="$OUTDIR" "$REPO/gem5_configs/x86_mixed.py" \
    --loader="$LOADER" \
    --ckpts $CKPTS \
    --load-cpu="$LOADCPU" \
    --maxinsts="$MAXINSTS" $PMU
RC=$?

echo ""
echo "=== ROI (DerivO3CPU) ==="
"$REPO/launch_scripts/parse_roi_stats.py" "$OUTDIR" 2>/dev/null
echo "--- CSVs de PMU ---"
ls -la "$OUTDIR"/CPU_*.csv 2>/dev/null || echo "(ninguno)"
exit $RC

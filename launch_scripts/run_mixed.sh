#!/bin/bash
# run_mixed.sh - Restauracion RMC con el ROI en O3.
#
#   ./run_mixed.sh <tag> <maxinsts> <timing|atomic> [--pmu] <ckpt1> [ckpt2 ...]
#
# Un checkpoint  -> single-thread.
# N checkpoints  -> SMT-N multiprogramado sobre un mismo nucleo O3.
#
# RMC_RESTORE=auto|direct|loader (auto): direct = gem5 instala el checkpoint
# sin simular el loader y la O3 arranca ya en el ROI; loader = el loader en la
# CPU simple (timing|atomic) y switch a O3 en su m5_exit. RMC_WARMUP=N: en
# directo, N instrucciones en la CPU simple antes de pasar a O3.
#
# Variables de entorno: GEM5_BIN, LOADER, CKPT_DIR, OUT_BASE, LOADER_OPTS,
# RMC_RESTORE, RMC_WARMUP.
# Remapeos de rutas: los <ckpt>.remap que deja regenerate_ckpt_noavx.sh
# --upload junto a cada checkpoint (mas LOADER_OPTS="OLD=NEW ...").
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
[ $# -eq 0 ] && die "falta al menos un checkpoint"
# Rutas absolutas: gem5 se lanza con el CWD en el outdir (ver arriba), asi que
# un checkpoint relativo dejaria de encontrarse.
CKPTS=""
for c in "$@"; do
    [ -f "$c" ] || die "no existe el checkpoint $c"
    CKPTS="$CKPTS $(realpath "$c")"
done
CKPTS="${CKPTS# }"
# shellcheck disable=SC2086
REMAPS="$(ckpt_remaps $CKPTS)"

OUTDIR="$OUT_BASE/$TAG"
mkdir -p "$OUTDIR"
rm -f "$OUTDIR"/CPU_*.csv

echo "=================================================="
echo " tag        : $TAG"
echo " checkpoints: $CKPTS"
echo " restaura   : ${RMC_RESTORE:-auto}   carga/calentamiento: $LOADCPU  (${RMC_WARMUP:-0} insts)"
echo " ROI        : DerivO3CPU + caches L1/L2  $PMU"
echo " maxinsts   : $MAXINSTS (por hilo)"
echo " remapeos   : ${REMAPS:-(ninguno)}"
echo " outdir     : $OUTDIR"
echo "=================================================="

cd "$OUTDIR"
"$GEM5_BIN" --outdir="$OUTDIR" "$REPO/gem5_configs/x86_mixed.py" \
    --loader="$(realpath "$LOADER")" \
    --loader-pie="$(realpath "$LOADER_PIE")" \
    --ckpts $CKPTS \
    --load-cpu="$LOADCPU" \
    --restore="${RMC_RESTORE:-auto}" --warmup="${RMC_WARMUP:-0}" \
    --maxinsts="$MAXINSTS" --loader-opts="$REMAPS" $PMU
RC=$?

echo ""
echo "=== ROI (DerivO3CPU) ==="
"$REPO/launch_scripts/parse_roi_stats.py" "$OUTDIR" 2>/dev/null
echo "--- CSVs de PMU ---"
ls -la "$OUTDIR"/CPU_*.csv 2>/dev/null || echo "(ninguno)"
exit $RC

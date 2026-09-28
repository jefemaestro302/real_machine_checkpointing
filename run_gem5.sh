#!/bin/bash
# run_gem5.sh — OBSOLETO: se mantiene como atajo hacia launch_scripts/.
#
#   ./run_gem5.sh <checkpoint.ckpt> [--cpu atomic|timing|o3] [--maxinsts N]
#
# La version anterior lanzaba configs/deprecated/example/se.py con el loader.
# Eso ya no sirve: el loader ejecuta m5_exit en la frontera del ROI, se.py
# termina la simulacion ahi (antes de simular el ROI), y el tipo "O3CPU" ni
# siquiera es valido en se.py. Las configs del repo (gem5_configs/) si tratan
# ese m5_exit como el inicio del ROI.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

CKPT="${1:?uso: $0 <checkpoint.ckpt> [--cpu atomic|timing|o3] [--maxinsts N]}"
shift
CPU="atomic"
MAX_INSTS="1000000"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --cpu)      CPU="$2"; shift 2 ;;
        --maxinsts) MAX_INSTS="$2"; shift 2 ;;
        *) echo "Argumento desconocido: $1 (GEM5_BIN y demas rutas: launch_scripts/_common.sh)"; exit 1 ;;
    esac
done

case "$CPU" in
    atomic|timing) exec "$HERE/launch_scripts/run_st_timing.sh" "$CKPT" "$MAX_INSTS" "$CPU" ;;
    o3|O3)         exec "$HERE/launch_scripts/run_mixed.sh" "$(basename "$CKPT" .ckpt)_o3" \
                        "$MAX_INSTS" timing "$CKPT" ;;
    *) echo "CPU desconocida: $CPU (atomic, timing u o3)"; exit 1 ;;
esac

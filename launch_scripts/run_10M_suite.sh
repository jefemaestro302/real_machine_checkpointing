#!/bin/bash
# run_10M_suite.sh - Suite de 10M instrucciones de ROI: mcf ST, perlbench ST
# y la mezcla SMT-2. Lanza los tres en paralelo por SLURM y al terminar
# imprime la tabla de IPC y MPKI.
set -u
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"
R="$REPO/launch_scripts/run_mixed.sh"
MCF="${MCF_CKPT:-$CKPT_DIR/dump_mcf_r_noavx.ckpt}"
# Nombres que produce regenerate_ckpt_noavx.sh (dump_<nombre>.ckpt)
PERL="${PERL_CKPT:-$CKPT_DIR/dump_perlbench_noavx.ckpt}"
N="${N_INSTS:-10000000}"
[ -f "$MCF" ]  || die "no existe $MCF  (MCF_CKPT=...)"
[ -f "$PERL" ] || die "no existe $PERL  (PERL_CKPT=...)"
SR="srun --ntasks=1 --partition=compute --time=02:00:00 --cpus-per-task=1"

$SR "$R" st_mcf_10M        "$N" timing --pmu "$MCF"         > /tmp/10M_mcf.log  2>&1 &
$SR "$R" st_perlbench_10M  "$N" timing --pmu "$PERL"        > /tmp/10M_perl.log 2>&1 &
$SR "$R" smt2_mcf_perl_10M "$N" timing --pmu "$MCF" "$PERL" > /tmp/10M_smt2.log 2>&1 &
wait

echo "=== SUITE DE 10M COMPLETA ==="
"$REPO/launch_scripts/parse_roi_stats.py" \
    "$OUT_BASE/st_mcf_10M" "$OUT_BASE/st_perlbench_10M" "$OUT_BASE/smt2_mcf_perl_10M"

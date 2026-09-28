#!/bin/bash
#SBATCH --job-name=gem5_perlbench
#SBATCH --output=slurm_perlbench.out
#SBATCH --error=slurm_perlbench.err
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --time=24:00:00
#
# Simula perlbench desde su checkpoint en gem5 (CPU simple). Los checkpoints
# generados en Docker guardan rutas /spec2017/...: se remapean a la
# instalacion local de SPEC.
#
#   sbatch test_perlbench_slurm.sh      (desde la raiz del repo)
set -euo pipefail
REPO="${SLURM_SUBMIT_DIR:-$(cd "$(dirname "$0")" && pwd)}"
source "$REPO/launch_scripts/_common.sh"
check_built

CHECKPOINT="${CHECKPOINT:-$CKPT_DIR/dump_perlbench_noavx.ckpt}"
PERLBENCH_RUN_DIR="$HOME/spec_cpu_2017/benchspec/CPU/500.perlbench_r/run/run_base_train_test_compilacion-m64.0000"

cd "$PERLBENCH_RUN_DIR"
echo "=== gem5: perlbench desde $CHECKPOINT ==="
LOADER_OPTS="/spec2017/=$HOME/spec_cpu_2017/" \
    "$REPO/launch_scripts/run_st_timing.sh" "$CHECKPOINT" 10000000 timing
echo "=== Hecho ==="

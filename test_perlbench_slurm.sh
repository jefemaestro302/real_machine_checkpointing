#!/bin/bash
#SBATCH --job-name=gem5_perlbench
#SBATCH --output=slurm_perlbench.out
#SBATCH --error=slurm_perlbench.err
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --time=24:00:00

# Directory where we uploaded our materials
TFM_DIR="$HOME/TFM"
GEM5_BIN="$HOME/gap_gem5/gem5/build/X86/gem5.opt"
CFG_SCRIPT="$TFM_DIR/gem5_scripts/X86/x86_st.py"
LOADER="$TFM_DIR/repositories/real_machine_checkpoint/build/loader"

# Where we put perlbench and dump
CHECKPOINT="$HOME/checkpoints/dump_perlbench.ckpt"
PERLBENCH_RUN_DIR="$HOME/spec_cpu_2017/benchspec/CPU/500.perlbench_r/run/run_base_train_test_compilacion-m64.0000"

cd $PERLBENCH_RUN_DIR

echo "=== Running gem5 simulated Perlbench from checkpoint ==="
# Map /spec2017 (the docker mount path) to the local Altek SPEC CPU path
export GLIBC_TUNABLES="glibc.cpu.hwcaps=-SSE4_2,-SSE4_1,-SSSE3,-AVX,-AVX2,-AVX512F"

rm -rf m5out
$GEM5_BIN --outdir=m5out $CFG_SCRIPT \
    --cmd="$LOADER" \
    --options="$CHECKPOINT /spec2017/=$HOME/spec_cpu_2017/" \
    --maxinsts=10000000 \
    --pmudispatch --pmuissue

echo "=== Done ==="

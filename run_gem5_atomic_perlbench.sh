#!/bin/bash
#SBATCH --job-name=gem5_atomic_ckpt
#SBATCH --output=slurm_atomic_ckpt.out
#SBATCH --error=slurm_atomic_ckpt.err
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --time=24:00:00

TFM_DIR="$HOME/TFM"
GEM5_BIN="$HOME/gap_gem5/gem5/build/X86/gem5.opt"
CFG_SCRIPT="$HOME/gap_gem5/gem5/configs/deprecated/example/se.py"

PERLBENCH_RUN_DIR="$HOME/spec_cpu_2017/benchspec/CPU/500.perlbench_r/run/run_base_train_test_compilacion-m64.0000"
cd $PERLBENCH_RUN_DIR

echo "=== Running gem5 AtomicSimpleCPU to generate baseline checkpoint ==="
export GLIBC_TUNABLES="glibc.cpu.hwcaps=-SSE4_2,-SSE4_1,-SSSE3,-AVX,-AVX2,-AVX512F"

rm -rf m5out_atomic
/usr/bin/time -v $GEM5_BIN --outdir=m5out_atomic $CFG_SCRIPT \
    --cpu-type=AtomicSimpleCPU \
    --cmd="./perlbench_r_base.test_compilacion-m64" \
    --options="-I. -I./lib diffmail.pl 2 550 15 24 23 100" \
    --maxinsts=10000000 \
    --take-checkpoints=10000000,1

echo "=== Done ==="

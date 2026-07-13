#!/bin/bash
#SBATCH --job-name=gem5_smt2_multiprogrammed
#SBATCH --output=slurm_smt2_multiprogrammed.out
#SBATCH --error=slurm_smt2_multiprogrammed.err
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --time=48:00:00
#SBATCH --partition=compute

GEM5_BIN="$HOME/gap_gem5/gem5/build/X86/gem5.opt"
CFG_SCRIPT="$HOME/TFM/gem5_scripts/X86/x86_smt_multiprogrammed.py"
LOADER_BIN="$HOME/TFM/repositories/real_machine_checkpoint/build/loader"

CKPT_PERLBENCH="$HOME/checkpoints/dump_perlbench_r_base.test_compilacion-m64.ckpt"
CKPT_GCC="$HOME/checkpoints/dump_cpugcc_r_base.test_compilacion-m64.ckpt"
CKPT_MCF="$HOME/checkpoints/dump_mcf_r_base.test_compilacion-m64.ckpt"
CKPT_LBM="$HOME/checkpoints/dump_lbm_r_base.test_compilacion-m64.ckpt"

echo "=== Running SMT-2 4-Way Multiprogrammed Workload ==="

rm -rf m5out_smt2
/usr/bin/time -v $GEM5_BIN --outdir=m5out_smt2 $CFG_SCRIPT \
    --loader=$LOADER_BIN \
    --ckpts $CKPT_PERLBENCH $CKPT_GCC $CKPT_MCF $CKPT_LBM \
    --maxinsts=10000000

echo "=== Done ==="

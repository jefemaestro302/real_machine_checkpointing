#!/bin/bash
set -e

REMOTE_DIR="altek1.gap.upv.es:~/spec_cpu_2017/benchspec/CPU/500.perlbench_r/exe"
CHECKPOINT_DIR="altek1.gap.upv.es:~/checkpoints"

echo "=== Uploading executable to Altek ==="
scp specs/benchspec/CPU/500.perlbench_r/run/run_base_train_test_compilacion-m64.0000/perlbench_r_base.test_compilacion-m64 $REMOTE_DIR/perlbench_r_base.test_compilacion-m64

echo "=== Uploading checkpoint to Altek ==="
ssh altek1.gap.upv.es "mkdir -p ~/checkpoints"
scp dump_perlbench.ckpt $CHECKPOINT_DIR/dump_perlbench.ckpt

echo "=== Uploading SLURM script to Altek ==="
scp test_perlbench_slurm.sh altek1.gap.upv.es:~/test_perlbench_slurm.sh

echo "=== Uploading updated loader to Altek ==="
scp build/loader altek1.gap.upv.es:~/TFM/repositories/real_machine_checkpoint/build/loader

echo "=== Upload Complete! ==="

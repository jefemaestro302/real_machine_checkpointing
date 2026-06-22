#!/bin/bash
set -e

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <benchmark_name>"
    echo "Example: $0 500.perlbench_r"
    exit 1
fi

BENCH=$1
RUN_DIR="specs/benchspec/CPU/${BENCH}/run/run_base_train_test_compilacion-m64.0000"
REMOTE_BASE="altek1.gap.upv.es:~/spec_cpu_2017/benchspec/CPU/${BENCH}"
CHECKPOINT_DIR="altek1.gap.upv.es:~/checkpoints"

if [ ! -d "$RUN_DIR" ]; then
    echo "Error: Directory $RUN_DIR does not exist. Did you run the generation script?"
    exit 1
fi

echo "================================================="
echo "   Syncing $BENCH to Altek"
echo "================================================="

echo "=== 1. Syncing Run Directory (Inputs & Binaries) ==="
# We use rsync to ensure all inputs and the executable are synced perfectly into the native SPEC tree
rsync -avz --progress \
    ${RUN_DIR} \
    ${REMOTE_BASE}/run/

echo "=== 2. Uploading Checkpoints ==="
ssh altek1.gap.upv.es "mkdir -p ~/checkpoints"
# Find any .ckpt files for this benchmark and upload them
find . -maxdepth 1 -name "dump_*${BENCH#*.ckpt}*.ckpt" -o -name "*.ckpt" | while read ckpt; do
    echo "Uploading $ckpt..."
    scp "$ckpt" $CHECKPOINT_DIR/
done

echo "=== 3. Uploading SLURM script template ==="
# Note: Ensure you edit the SLURM script on Altek to point to the correct benchmark if needed
if [ -f "test_perlbench_slurm.sh" ]; then
    scp test_perlbench_slurm.sh altek1.gap.upv.es:~/TFM/launch_scripts/test_spec_slurm.sh
fi

echo "=== 4. Uploading updated loader ==="
scp build/loader altek1.gap.upv.es:~/TFM/repositories/real_machine_checkpoint/build/loader

echo "================================================="
echo "   Upload Complete for $BENCH!"
echo "================================================="

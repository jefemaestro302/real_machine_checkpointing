#!/bin/bash
set -e

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <benchmark_name>"
    echo "Example: $0 500.perlbench_r"
    exit 1
fi

BENCH_ARG=$1

# List of integer benchmarks in SPEC CPU2017 to sync if "all" is specified
ALL_BENCHMARKS=(
    "500.perlbench_r"
    "502.gcc_r"
    "505.mcf_r"
    "519.lbm_r"
    "520.omnetpp_r"
    "523.xalancbmk_r"
    "525.x264_r"
    "531.deepsjeng_r"
    "538.imagick_r"
    "541.leela_r"
    "544.nab_r"
    "557.xz_r"
)

if [ "$BENCH_ARG" == "all" ]; then
    BENCHMARKS=("${ALL_BENCHMARKS[@]}")
else
    BENCHMARKS=("$BENCH_ARG")
fi

echo "=== Uploading SLURM script template & loader first ==="
if [ -f "test_perlbench_slurm.sh" ]; then
    scp test_perlbench_slurm.sh altek1.gap.upv.es:~/TFM/launch_scripts/test_spec_slurm.sh
fi
scp build/loader altek1.gap.upv.es:~/TFM/repositories/real_machine_checkpoint/build/loader

for BENCH in "${BENCHMARKS[@]}"; do
    RUN_DIR="specs/benchspec/CPU/${BENCH}/run/run_base_train_test_compilacion-m64.0000"
    REMOTE_BASE="altek1.gap.upv.es:~/spec_cpu_2017/benchspec/CPU/${BENCH}"
    CHECKPOINT_DIR="altek1.gap.upv.es:~/checkpoints"

    if [ ! -d "$RUN_DIR" ]; then
        echo "Skipping $BENCH: Directory $RUN_DIR does not exist."
        continue
    fi

    echo "================================================="
    echo "   Syncing $BENCH to Altek"
    echo "================================================="

    echo "=== 1. Syncing Run Directory ==="
    rsync -avz --progress \
        ${RUN_DIR} \
        ${REMOTE_BASE}/run/

    echo "=== 2. Uploading Checkpoints ==="
    ssh altek1.gap.upv.es "mkdir -p ~/checkpoints"
    find . -maxdepth 1 -name "dump_*${BENCH#*.ckpt}*.ckpt" -o -name "*.ckpt" | grep "${BENCH#*.}" | while read ckpt; do
        echo "Uploading $ckpt..."
        scp "$ckpt" $CHECKPOINT_DIR/
    done

    echo "=== Sync Complete for $BENCH! ==="
done

echo "================================================="
echo "   All Uploads Complete!"
echo "================================================="

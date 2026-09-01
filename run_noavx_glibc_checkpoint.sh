#!/bin/bash
# =============================================================================
# run_noavx_glibc_checkpoint.sh
#
# Full workflow for generating a gem5-compatible checkpoint of Tailbench Silo
# using a glibc compiled with --disable-multi-arch (no AVX IFUNCs).
#
# Steps:
#   1. [Optional] Build the tailbench_noavx_glibc Docker image
#   2. Build libckpt.so and loader inside the container
#   3. Build Silo inside the container
#   4. Run Silo through the NO-AVX glibc's dynamic linker with a 3s checkpoint
#   5. [LOCAL TEST] Restore the checkpoint with ./build/loader
#   6. [REMOTE]    rsync everything and run gem5 on the remote machine
#
# Usage:
#   ./run_noavx_glibc_checkpoint.sh [--skip-build] [--skip-gem5]
#
#   --skip-build   : Skip rebuilding the Docker image (use if already built)
#   --skip-gem5    : Skip the remote gem5 step (only run local test)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_IMAGE=1
RUN_GEM5=1

for arg in "$@"; do
    case "$arg" in
        --skip-build) BUILD_IMAGE=0 ;;
        --skip-gem5)  RUN_GEM5=0 ;;
    esac
done

DOCKER_IMAGE="tailbench_noavx_glibc"
CKPT_FILE="tailbench_noavx_3s.ckpt"
SILO_DIR="/workspace/Tailbench/tailbench/silo"
NOAVX_GLIBC="/opt/glibc-noavx"

# Checkpoint at 3 seconds = 3,000,000,000 ns
CKPT_NS=3000000000

echo "============================================================"
echo "  Tailbench Silo — NO-AVX glibc Checkpoint (3 s)"
echo "============================================================"

# ---------------------------------------------------------------------------
# STEP 1: Build Docker image (only if requested)
# ---------------------------------------------------------------------------
if [[ "$BUILD_IMAGE" -eq 1 ]]; then
    echo ""
    echo "[1/6] Building Docker image: $DOCKER_IMAGE"
    echo "      (This compiles glibc from source — expect ~10 minutes)"
    echo "------------------------------------------------------------"
    docker build \
        -f "$SCRIPT_DIR/docker/Dockerfile.noavx_glibc" \
        -t "$DOCKER_IMAGE" \
        "$SCRIPT_DIR"
    echo "[1/6] Image built successfully."
else
    echo "[1/6] Skipping Docker image build (--skip-build)."
fi

# ---------------------------------------------------------------------------
# STEP 2-4: Build + run inside Docker
# ---------------------------------------------------------------------------
echo ""
echo "[2-4/6] Running inside Docker: build + checkpoint generation"
echo "------------------------------------------------------------"

docker run --rm --privileged \
    -v "$SCRIPT_DIR":/workspace \
    "$DOCKER_IMAGE" /bin/bash -c "
set -euo pipefail

NOAVX_GLIBC='$NOAVX_GLIBC'
SILO_DIR='$SILO_DIR'
CKPT_FILE='$CKPT_FILE'
CKPT_NS='$CKPT_NS'

# ---- [2] Build libckpt.so and loader --------------------------------
echo ''
echo '[2/6] Building libckpt.so and loader...'
cd /workspace

# Build dumper object (PIC version for the shared lib)
gcc -O2 -g -Wall -fPIC \
    -mno-avx -mno-avx2 -mno-avx512f \
    -c src/dumper.c -o build/dumper_pic.o -Isrc

# Build libckpt.so
gcc -O2 -g -Wall -fPIC -shared \
    -mno-avx -mno-avx2 -mno-avx512f \
    -o build/libckpt.so src/libckpt.c build/dumper_pic.o \
    -Isrc -ldl -lpthread
echo '[2/6] libckpt.so built.'

# Build the static loader (used by gem5 to restore the checkpoint)
gcc -O2 -g -Wall \
    -mno-avx -mno-avx2 -mno-avx512f \
    -fno-stack-protector \
    -static -no-pie \
    -Wl,-Ttext-segment=0x20000000 \
    -o build/loader src/loader.c \
    -Isrc
echo '[2/6] loader built.'

# ---- [3] Build Silo (harness + silo) --------------------------------
echo ''
echo '[3/6] Building Tailbench harness and Silo...'
cd /workspace/Tailbench/tailbench/harness && make -j\$(nproc) 2>&1 | tail -5
cd /workspace/Tailbench/tailbench/silo
./build.sh 2>&1 | tail -10
echo '[3/6] Silo built.'

# ---- Verify: no AVX in Silo binary ----------------------------------
echo ''
echo '[3/6] Verifying no AVX in Silo binary...'
SILO_BIN=\$SILO_DIR/out-perf.masstree/benchmarks/dbtest_integrated
if objdump -d \"\$SILO_BIN\" | grep -iqE '\b(vmovaps|vmovups|vmovdqu|vpbroadcast|ymm[0-9])\b'; then
    echo 'WARNING: AVX instructions found in Silo binary! Check build flags.'
else
    echo 'OK: Silo binary is AVX-free.'
fi

# ---- Verify: no AVX in new glibc ------------------------------------
echo ''
echo '[3/6] Verifying no AVX in /opt/glibc-noavx/lib/libc.so.6...'
if objdump -d \"\$NOAVX_GLIBC/lib/libc.so.6\" | grep -iqE '\b(vmovaps|vmovups|vmovdqu|vpbroadcast|ymm[0-9])\b'; then
    echo 'ERROR: AVX instructions found in the no-avx glibc! Rebuild the Docker image.'
    exit 1
else
    echo 'OK: No-AVX glibc is clean.'
fi

# ---- [4] Generate checkpoint ----------------------------------------
echo ''
echo '[4/6] Starting Silo with no-AVX glibc — checkpoint fires after 3 seconds...'
echo '     Dynamic linker: \$NOAVX_GLIBC/lib/ld-linux-x86-64.so.2'
echo '     Output:        \$SILO_DIR/\$CKPT_FILE'

cd \$SILO_DIR

# We launch the binary through the no-AVX glibc dynamic linker.
# LD_PRELOAD is passed as a real env var — the custom linker honours it.
# All TBENCH_* and CKPT_* vars are also set as real environment variables.
# The 3s timer (CKPT_AFTER_NS) will fire while Silo is processing requests.
env \
    LD_PRELOAD=\"/workspace/build/libckpt.so\" \
    LD_LIBRARY_PATH=\"\$NOAVX_GLIBC/lib:\$SILO_DIR/third-party/lz4\" \
    TBENCH_QPS=500 \
    TBENCH_MAXREQS=1000000 \
    TBENCH_WARMUPREQS=5 \
    CKPT_OUTPUT=\"\$SILO_DIR/\$CKPT_FILE\" \
    CKPT_AFTER_NS=\"\$CKPT_NS\" \
\"\$NOAVX_GLIBC/lib/ld-linux-x86-64.so.2\" \
    --library-path \"\$NOAVX_GLIBC/lib:\$SILO_DIR/third-party/lz4\" \
    ./out-perf.masstree/benchmarks/dbtest_integrated \
    --bench tpcc \
    --num-threads 1 \
    --scale-factor 1 \
    --retry-aborted-transactions \
    --ops-per-worker 100000 \
    2>&1 | tail -40 || true

if [[ -f \"\$SILO_DIR/\$CKPT_FILE\" ]]; then
    echo ''
    echo '[4/6] Checkpoint generated!'
    ls -lh \"\$SILO_DIR/\$CKPT_FILE\"
else
    echo '[4/6] ERROR: Checkpoint file not found!'
    exit 1
fi
"

# Copy the checkpoint to the workspace root for convenience
CKPT_PATH="$SCRIPT_DIR/Tailbench/tailbench/silo/$CKPT_FILE"
echo ""
echo "Checkpoint: $CKPT_PATH ($(du -h "$CKPT_PATH" | cut -f1))"

# ---------------------------------------------------------------------------
# STEP 5: Local restore test
# ---------------------------------------------------------------------------
echo ""
echo "[5/6] Local restore test — running checkpoint through ./build/loader"
echo "------------------------------------------------------------"
"$SCRIPT_DIR/build/loader" "$CKPT_PATH" && {
    echo "[5/6] Local restore: PASSED"
} || {
    echo "[5/6] Local restore: FAILED (exit code $?)"
    echo "      Check loader output above for details."
    exit 1
}

# ---------------------------------------------------------------------------
# STEP 6: Remote gem5 test
# ---------------------------------------------------------------------------
if [[ "$RUN_GEM5" -eq 0 ]]; then
    echo ""
    echo "[6/6] Skipping remote gem5 step (--skip-gem5)."
    echo ""
    echo "============================================================"
    echo "  Done! Next: copy checkpoint to remote and run gem5."
    echo "  rsync -avz $CKPT_PATH azha:~/..."
    echo "  ./run_gem5.sh $CKPT_FILE --cpu o3"
    echo "============================================================"
    exit 0
fi

echo ""
echo "[6/6] Syncing to remote (azha) and running gem5..."
echo "------------------------------------------------------------"

# Sync source + binaries (no .ckpt files — too large; we transfer separately)
rsync -avz --progress \
    --exclude '.git/' \
    --exclude 'm5out/' \
    --exclude '*.ckpt' \
    "$SCRIPT_DIR/" azha:proyectos_personales/checkpoint_maquina_real/real_machine_checkpoint/

# Transfer the checkpoint specifically
echo "Transferring checkpoint..."
rsync -avz --progress \
    "$CKPT_PATH" \
    "azha:proyectos_personales/checkpoint_maquina_real/real_machine_checkpoint/Tailbench/tailbench/silo/$CKPT_FILE"

# Run gem5 remotely
echo ""
echo "Running gem5 on remote (azha)..."
ssh azha "
    cd proyectos_personales/checkpoint_maquina_real/real_machine_checkpoint && \
    ./run_gem5.sh Tailbench/tailbench/silo/$CKPT_FILE --cpu o3 --maxinsts 10000000
"

echo ""
echo "============================================================"
echo "  All steps complete!"
echo "  gem5 stats: check azha:~/...real_machine_checkpoint/m5out/stats.txt"
echo "============================================================"

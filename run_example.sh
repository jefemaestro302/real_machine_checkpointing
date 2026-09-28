#!/bin/bash
# run_example.sh - Local (host) checkpoint/restore example, no gem5.
#
# Builds example.c, checkpoints it at its first call to target_function()
# with libckpt.so (CKPT_AT_SYMBOL), and restores it with the loader in
# --native mode (m5_exit is an illegal instruction outside gem5).
set -euo pipefail
cd "$(dirname "$0")"

echo "==========================================="
echo "  Real Machine Checkpoint - Local Example  "
echo "==========================================="

# ASLR off, as the loader assumes. setarch must wrap env (libckpt.so removes
# LD_PRELOAD from the environment of the process it is loaded into).
NORAND="setarch -R"
$NORAND true 2>/dev/null || NORAND=""

echo "[1] Compiling example.c..."
gcc -O0 -g example.c -o example

echo "[2] Building libckpt.so and the loaders..."
make build/libckpt.so build/loader build/loader_pie >/dev/null

echo "[3] Running the example with LD_PRELOAD (CKPT_AT_SYMBOL=target_function)..."
rm -f example_dump.ckpt
$NORAND env LD_PRELOAD=./build/libckpt.so \
    CKPT_AT_SYMBOL=target_function \
    CKPT_OUTPUT=example_dump.ckpt \
    ./example || true

echo ""
[ -f example_dump.ckpt ] || { echo "[!] example_dump.ckpt was not generated"; exit 1; }
ls -lh example_dump.ckpt

echo ""
echo "[4] Restoring from the checkpoint (loader --native)..."
LOADER_BIN="$(python3 gem5_configs/rmc_common.py example_dump.ckpt build)"
$NORAND "$LOADER_BIN" example_dump.ckpt --native

echo "[+] Success!"

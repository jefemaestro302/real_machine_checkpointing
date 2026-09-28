#!/bin/bash
# run_example.sh - Local (host) checkpoint/restore example, no gem5.
#
# Builds example.c, checkpoints it at its first call to target_function()
# (launch_scripts/gen_ckpt.sh -s, i.e. libckpt.so with CKPT_AT_SYMBOL), and
# restores it with the loader in --native mode (m5_exit is an illegal
# instruction outside gem5).
set -euo pipefail
cd "$(dirname "$0")"

echo "==========================================="
echo "  Real Machine Checkpoint - Local Example  "
echo "==========================================="

echo "[1] Compiling example.c..."
gcc -O0 -g example.c -o example

echo "[2] Building libckpt.so and the loaders..."
make build/libckpt.so build/loader build/loader_pie >/dev/null

echo "[3] Checkpointing at the first call to target_function (gen_ckpt.sh)..."
launch_scripts/gen_ckpt.sh -w -s target_function -o "$PWD/example_dump.ckpt" -- ./example
cat example_dump.ckpt.stdout

echo ""
[ -f example_dump.ckpt ] || { echo "[!] example_dump.ckpt was not generated"; exit 1; }
ls -lh example_dump.ckpt

echo ""
echo "[4] Restoring from the checkpoint (loader --native)..."
LOADER_BIN="$(python3 gem5_configs/rmc_common.py example_dump.ckpt build)"
setarch -R "$LOADER_BIN" example_dump.ckpt --native

echo "[+] Success!"

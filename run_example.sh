#!/bin/bash

set -e

echo "==========================================="
echo "  Real Machine Checkpoint - Local Example  "
echo "==========================================="

# 1. Compile the example program
echo "[1] Compiling example.c..."
gcc -O0 -g example.c -o example

# 2. Compile libckpt and the loader just in case
echo "[2] Compiling libckpt.so and loader..."
mkdir -p build
gcc -fPIC -shared -o build/libckpt.so src/libckpt.c src/dumper.c -ldl
gcc src/loader.c -I src -o build/loader -static

# 3. Run the example to generate the checkpoint
echo "[3] Running the example with LD_PRELOAD..."
echo "    We will set CKPT_AT_SYMBOL=target_function so it automatically dumps!"
LD_PRELOAD=./build/libckpt.so \
CKPT_AT_SYMBOL=target_function \
CKPT_OUTPUT=example_dump.ckpt \
./example || true

echo ""
echo "[*] Checkpoint successfully generated! Looking for example_dump.ckpt:"
ls -lh example_dump.ckpt

echo ""
echo "[4] Restoring from the checkpoint..."
echo "    The program should resume from iteration 3 and finish!"
./build/loader example_dump.ckpt

echo "[+] Success!"

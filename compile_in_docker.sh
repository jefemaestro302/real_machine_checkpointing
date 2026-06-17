#!/bin/bash
set -e

echo "[+] Building Docker environment..."
docker build -t musl_builder -f docker/Dockerfile.musl .

echo "[+] Compiling real_machine_checkpoint (loader and libckpt_static.o)..."
docker run --rm -v "$(pwd)":/workspace -w /workspace musl_builder make clean all

echo ""
echo "[+] DONE! The static checkpoint library is at build/libckpt_static.o"
echo "[+] The loader is at build/loader"
echo ""
echo "To compile any app with checkpointing support inside the same clean environment, run:"
echo "docker run --rm -v \"\$(pwd)/YOUR_APP_DIR\":/app -v \"\$(pwd)/build\":/ckpt_build -w /app musl_builder gcc -static -o your_app your_app.c /ckpt_build/libckpt_static.o -lpthread"

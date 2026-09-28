#!/bin/bash
# generate_all_spec_checkpoints.sh - Compila los benchmarks SPEC sin AVX en
# Docker y genera sus checkpoints en el host.
#
# - Compilacion: en el contenedor gem5_noavx_env con specs/config/gem5_noavx.cfg
#   (los benchmarks se compilan siempre en local, nunca en el cluster).
#   `runcpu --action=setup` deja preparado el directorio de ejecucion
#   (run_base_train_...) con sus entradas.
# - Generacion: NO en Docker (su seccomp no deja desactivar ASLR con
#   setarch -R), sino por el camino unico, launch_scripts/gen_ckpt.sh, con los
#   benchmarks de launch_scripts/benchmarks.sh. Asi el checkpoint sale igual
#   que desde regenerate_ckpt_noavx.sh o e2e_altek.sh.
#
# Variables: CKPT_DIR (destino, por defecto el directorio actual).
set -euo pipefail
cd "$(dirname "$0")"
source launch_scripts/_common.sh
source launch_scripts/benchmarks.sh

echo "=== Compilando loaders y libckpt.so (host) ==="
make build/libckpt.so build/loader build/loader_pie >/dev/null

# Benchmarks de la tabla, con su nombre SPEC (505.mcf_r...)
SPEC_NAMES=()
for b in $RMC_BENCHMARKS; do
    bench_def "$b"
    SPEC_NAMES+=("${BENCH_RUNDIR%%/*}")
done

echo "=== Compilando SPEC en Docker (gem5_noavx.cfg): ${SPEC_NAMES[*]} ==="
docker run -i --rm \
    -v "$(pwd)":/workspace \
    -v "$(pwd)/specs":/spec2017 \
    gem5_noavx_env:latest \
    /bin/bash -c "set -e; cd /spec2017; source shrc;
        for bench in ${SPEC_NAMES[*]}; do
            runcpu --config=gem5_noavx.cfg --action=build \$bench
            runcpu --config=gem5_noavx.cfg --action=setup --size=train \$bench
        done"

echo "=== Generando checkpoints en el host (launch_scripts/gen_ckpt.sh) ==="
CKPT_DIR="${CKPT_DIR:-$(pwd)}" SPEC_DIR="$(pwd)/specs/benchspec/CPU" \
    launch_scripts/regenerate_ckpt_noavx.sh all

echo "=== Checkpoints en ${CKPT_DIR:-$(pwd)} ==="

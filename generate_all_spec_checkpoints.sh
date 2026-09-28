#!/bin/bash
# generate_all_spec_checkpoints.sh - Compila los benchmarks SPEC sin AVX en
# Docker y genera sus checkpoints en el host.
#
#   ./generate_all_spec_checkpoints.sh [--build-only] [all | mcf lbm ...]
#
# Requisitos: docker usable sin sudo y SPEC CPU2017 instalado en <repo>/specs
# (specs/shrc). La imagen gem5_noavx_env se construye si no existe
# (docker/Dockerfile.spec).
#
# - Compilacion: en el contenedor gem5_noavx_env con specs/config/gem5_noavx.cfg
#   (es la UNICA forma de compilar: siempre en local y en Docker, nunca en el
#   cluster). `runcpu --action=setup` deja preparado el directorio de
#   ejecucion (run_base_train_...) con sus entradas y su speccmds.cmd, de
#   donde benchmarks.sh saca el comando. "all" (por defecto) = todos los
#   benchmarks rate (intrate + fprate).
# - Generacion: NO en Docker (su seccomp no deja desactivar ASLR con
#   setarch -R), sino por el camino unico, launch_scripts/gen_ckpt.sh, con los
#   benchmarks de launch_scripts/benchmarks.sh. Asi el checkpoint sale igual
#   que desde regenerate_ckpt_noavx.sh o e2e_altek.sh. --build-only se la
#   salta (p.ej. antes de e2e_altek.sh, que genera los suyos).
#
# Un benchmark que no compile no detiene los demas (runcpu sigue); los que
# queden sin preparar se listan al final.
#
# Variables: CKPT_DIR (destino, por defecto el directorio actual).
set -euo pipefail
cd "$(dirname "$0")"
source launch_scripts/_common.sh
source launch_scripts/benchmarks.sh
SPEC_DIR="$(pwd -P)/specs/benchspec/CPU"

BUILD_ONLY=0
[ "${1:-}" = --build-only ] && { BUILD_ONLY=1; shift; }
WHAT=("$@")
[ ${#WHAT[@]} -eq 0 ] && WHAT=(all)
if [ "${WHAT[0]}" = all ]; then
    SPEC_NAMES=(intrate fprate)
else
    SPEC_NAMES=()
    for b in "${WHAT[@]}"; do b=${b#*.}; SPEC_NAMES+=("${b%_r}_r"); done
fi

[ -f specs/shrc ] || die "no hay SPEC CPU2017 instalado en $(pwd)/specs (falta specs/shrc; ver HANDOFF.md)"
[ -f specs/config/gem5_noavx.cfg ] || die "falta specs/config/gem5_noavx.cfg"
if ! docker image inspect gem5_noavx_env:latest >/dev/null 2>&1; then
    echo "=== Construyendo la imagen gem5_noavx_env (docker/Dockerfile.spec) ==="
    docker build -f docker/Dockerfile.spec -t gem5_noavx_env:latest docker/
fi

echo "=== Compilando SPEC en Docker (gem5_noavx.cfg, $RMC_SPEC_SIZE): ${SPEC_NAMES[*]} ==="
# Directorios de ejecucion viejos fuera: si existen, runcpu --action=setup no
# reutiliza el .0000 (y menos si run/list apunta a rutas de un arbol movido),
# sino que crea .0001, .0002..., y benchmarks.sh solo lee el .0000
if [ "${WHAT[0]}" = all ]; then
    BENCH_DIRS=("$SPEC_DIR"/*_r)
else
    BENCH_DIRS=()
    for b in "${SPEC_NAMES[@]}"; do BENCH_DIRS+=("$SPEC_DIR"/*."$b"); done
fi
for d in "${BENCH_DIRS[@]}"; do
    [ -d "$d/run" ] || continue
    rm -rf "$d/run/run_base_${RMC_SPEC_SIZE}_${RMC_SPEC_LABEL}".* "$d/run/list"
done

# --user: lo que runcpu crea en specs/ queda del usuario del host, que despues
# ejecuta los benchmarks en esos directorios (escriben sus salidas ahi).
# --rebuild: sin el, runcpu da por buenos los ejecutables que ya haya en exe/
# ("Up to date") aunque vengan de otra toolchain
docker run -i --rm --user "$(id -u):$(id -g)" -e HOME=/tmp \
    -v "$(pwd)":/workspace \
    -v "$(pwd)/specs":/spec2017 \
    gem5_noavx_env:latest \
    /bin/bash -c "cd /spec2017; source shrc;
        runcpu --config=gem5_noavx.cfg --action=build --rebuild ${SPEC_NAMES[*]}
        runcpu --config=gem5_noavx.cfg --action=setup --size=$RMC_SPEC_SIZE ${SPEC_NAMES[*]}
        exit 0"

echo "=== Preparados: $(bench_list | tr '\n' ' ') ==="
missing=$(bench_missing | tr '\n' ' ')
[ -n "$missing" ] && echo "=== SIN preparar (no compilan o faltan en SPEC): $missing ==="

[ "$BUILD_ONLY" = 1 ] && exit 0

echo "=== Compilando loaders y libckpt.so (host) ==="
make build/libckpt.so build/loader build/loader_pie >/dev/null

echo "=== Generando checkpoints en el host (launch_scripts/gen_ckpt.sh) ==="
CKPT_DIR="${CKPT_DIR:-$(pwd)}" SPEC_DIR="$SPEC_DIR" \
    launch_scripts/regenerate_ckpt_noavx.sh "${WHAT[@]}"

echo "=== Checkpoints en ${CKPT_DIR:-$(pwd)} ==="

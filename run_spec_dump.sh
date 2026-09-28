#!/bin/bash
# run_spec_dump.sh - Genera el checkpoint de perlbench en el directorio actual.
#
# Antes lo hacia dentro de Docker con la glibc sin AVX y un ld.so explicito;
# ahora pasa por el camino unico de generacion (launch_scripts/gen_ckpt.sh,
# via regenerate_ckpt_noavx.sh y la tabla launch_scripts/benchmarks.sh), en el
# host, para que el checkpoint salga igual que todos los demas.
set -euo pipefail
cd "$(dirname "$0")"
make build/libckpt.so build/loader build/loader_pie >/dev/null
CKPT_DIR="${CKPT_DIR:-$PWD}" exec launch_scripts/regenerate_ckpt_noavx.sh perlbench

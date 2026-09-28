#!/bin/bash
# regenerate_ckpt_noavx.sh - Genera los checkpoints SPEC aptos para gem5 SE.
#
#   ./regenerate_ckpt_noavx.sh [mcf|lbm|...|all]...
#
# "all" = todos los benchmarks rate con directorio de ejecucion preparado.
# Los benchmarks (directorio, binario, argumentos, instante del volcado) salen
# de benchmarks.sh, y la generacion la hace gen_ckpt.sh: ambos son la unica
# fuente de verdad, asi que un checkpoint sale igual lo genere este script,
# e2e_altek.sh o cualquier otro.
#
# Dos condiciones para que un checkpoint sea simulable en gem5 SE:
#
#  1. El BINARIO del benchmark no debe contener AVX/AVX2/BMI2. gem5 SE no las
#     implementa. Se consigue compilando con specs/config/gem5_noavx.cfg.
#     gen_ckpt.sh lo comprueba y se niega a generar si las encuentra.
#
#  2. La GLIBC tampoco debe ejecutarlas. Su resolvedor IFUNC elige rutas AVX2
#     al arrancar (memcpy, strlen, memchr...). gen_ckpt.sh exporta
#     GLIBC_TUNABLES para que se quede en las rutas SSE2, que gem5 si
#     implementa.
#
# Variables: SPEC_DIR (.../benchspec/CPU; por defecto <repo>/specs/... si
# existe, si no ~/spec_cpu_2017/...), CKPT_DIR (destino).
set -eu
HERE="$(dirname "${BASH_SOURCE[0]}")"
source "$HERE/_common.sh"
source "$HERE/benchmarks.sh"

SPEC_DIR="${SPEC_DIR:-$(default_spec_dir)}"
mkdir -p "$CKPT_DIR"

WHAT=("$@")
[ ${#WHAT[@]} -eq 0 ] && WHAT=(all)
[ "${WHAT[0]}" = all ] && mapfile -t WHAT < <(bench_list)
[ ${#WHAT[@]} -gt 0 ] || die "no hay benchmarks rate preparados en $SPEC_DIR (runcpu --action=setup)"

fails=0
for b in "${WHAT[@]}"; do
    bench_def "$b" || { echo "benchmark desconocido o sin preparar: $b ($SPEC_DIR)" >&2; fails=$((fails + 1)); continue; }
    bench_stdin_opt "$SPEC_DIR"
    "$HERE/gen_ckpt.sh" -o "$CKPT_DIR/dump_${BENCH_CKPT}.ckpt" -C "$SPEC_DIR/$BENCH_RUNDIR" \
        -t "$BENCH_NS" ${BENCH_STDIN_OPT[@]+"${BENCH_STDIN_OPT[@]}"} -- "./$BENCH_BIN" "${BENCH_ARGS[@]}" \
        || fails=$((fails + 1))
done
[ "$fails" -eq 0 ] || die "$fails checkpoint(s) no se generaron"
echo "=== Listo: $CKPT_DIR ==="

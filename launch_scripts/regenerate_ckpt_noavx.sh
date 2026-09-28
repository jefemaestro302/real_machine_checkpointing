#!/bin/bash
# regenerate_ckpt_noavx.sh - Genera checkpoints .ckpt aptos para gem5 SE.
#
#   ./regenerate_ckpt_noavx.sh [mcf|perlbench|all]
#
# Dos condiciones para que un checkpoint sea simulable en gem5 SE:
#
#  1. El BINARIO del benchmark no debe contener AVX/AVX2/BMI2. gem5 SE no las
#     implementa. Se consigue compilando con specs/config/gem5_noavx.cfg
#     (-mno-avx -mno-avx2 -mno-avx512f). Verificacion:
#         objdump -d $BIN | grep -cE '%ymm|bextr|shlx|sarx|shrx|vmovdq'   # -> 0
#
#  2. La GLIBC tampoco debe ejecutarlas. Su resolvedor IFUNC elige rutas AVX2
#     al arrancar (memcpy, strlen, memchr...). Donde no hay una glibc compilada
#     con --disable-multi-arch, GLIBC_TUNABLES desactiva esas capacidades y la
#     libreria se queda en las rutas SSE2, que gem5 si implementa.
set -eu
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"
[ -f "$LIBCKPT" ] || die "no existe $LIBCKPT  (ejecuta: make -C $REPO)"

SPEC_DIR="${SPEC_DIR:-$HOME/spec_cpu_2017/benchspec/CPU}"
NOAVX="glibc.cpu.hwcaps=-SSE4_2,-SSE4_1,-SSSE3,-AVX,-AVX2,-AVX512F,-AVX_Usable,-AVX2_Usable,-AVX512F_Usable,-AVX_Fast_Unaligned_Load"

mkdir -p "$CKPT_DIR"

check_noavx() {
    local n; n=$(objdump -d "$1" 2>/dev/null | grep -cE '%ymm|vpbroadcast|vzeroupper|vmovdq|bextr|shlx|sarx|shrx' || true)
    [ "$n" -eq 0 ] || die "$1 contiene $n instrucciones AVX/BMI2: gem5 SE abortara. Recompilalo con specs/config/gem5_noavx.cfg."
    echo "  [ok] sin AVX/BMI2: $(basename "$1")"
}

# ASLR desactivado (como supone el loader): direcciones reproducibles, y los
# binarios estaticos no PIE no pueden acabar con el heap encima del loader
# (0x20000000), cosa que la aleatorizacion del brk si permite.
# setarch envuelve a env, y no al reves: libckpt.so quita LD_PRELOAD del
# entorno del proceso que la carga, asi que con `env LD_PRELOAD=.. setarch`
# el benchmark (hijo de setarch) arrancaria SIN la libreria.
NORAND="setarch -R"
if ! $NORAND true 2>/dev/null; then
    echo "AVISO: setarch -R no disponible (p.ej. seccomp de Docker); se genera con ASLR" >&2
    NORAND=""
fi
GEN_TIMEOUT="${GEN_TIMEOUT:-900}"   # segundos maximos hasta tener el volcado

gen() {   # gen <nombre> <dir_run> <binario> <ns> <args...>
    local name=$1 dir=$2 bin=$3 ns=$4; shift 4
    local out="$CKPT_DIR/dump_${name}.ckpt"
    local log="$CKPT_DIR/gen_${name}.log"
    [ -d "$dir" ] || die "no existe el directorio de ejecucion $dir"
    check_noavx "$dir/$bin"
    echo "=== Generando $name (CKPT_AFTER_NS=$ns) ==="
    rm -f "$out" "$out.tmp"
    # exec: el PID de fondo es el propio benchmark, no un subshell que
    # sobreviviria al kill dejando el benchmark corriendo.
    ( cd "$dir" && exec $NORAND env GLIBC_TUNABLES="$NOAVX" CKPT_AFTER_NS="$ns" \
        CKPT_OUTPUT="$out" LD_PRELOAD="$LIBCKPT" "./$bin" "$@" \
        >/dev/null 2>"$log" ) &
    local pid=$!
    # El dumper escribe <out>.tmp y lo renombra a <out> SOLO al terminar: que
    # exista <out> significa volcado completo. Antes se esperaba a que el
    # fichero existiera y se mataba 4 s despues, con lo que un volcado lento
    # (GBs en NFS) quedaba truncado y con los offsets de las regiones a 0.
    local t=0
    while [ ! -f "$out" ] && kill -0 "$pid" 2>/dev/null && [ "$t" -lt "$GEN_TIMEOUT" ]; do
        sleep 1; t=$((t + 1))
    done
    kill -9 "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    rm -f "$out.tmp"
    grep -E "RIP=|regions|file descriptors|Dump complete|ERROR" "$log" || true
    if [ ! -f "$out" ] || ! grep -q "Dump complete" "$log"; then
        die "no se completo el volcado de $name (ver $log)"
    fi
    ls -la "$out"
}

WHAT=${1:-all}

if [ "$WHAT" = "mcf" ] || [ "$WHAT" = "all" ]; then
    # CKPT_AFTER_NS=5s: cae dentro de la meseta de IPC estable [1,1s-15,9s]
    # medida con perf en máquina real (IPC nativo ~1,0, CV 12%). 10ms (valor
    # usado hasta 2026-09-01) capturaba el pico de arranque/parseo de
    # inp.in, no representativo de la fase de cómputo de mcf.
    gen mcf_r_noavx "$SPEC_DIR/505.mcf_r/run/run_base_train_test_compilacion-m64.0000" \
        mcf_r_base.test_compilacion-m64 5000000000 inp.in
fi
if [ "$WHAT" = "perlbench" ] || [ "$WHAT" = "all" ]; then
    gen perlbench_noavx "$SPEC_DIR/500.perlbench_r/run/run_base_train_test_compilacion-m64.0000" \
        perlbench_r_base.test_compilacion-m64 3000000000 -I./lib diffmail.pl 2 550 15 24 23 100
fi
echo "=== Listo ==="

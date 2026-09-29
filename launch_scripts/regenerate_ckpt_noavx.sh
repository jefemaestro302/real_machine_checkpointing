#!/bin/bash
# regenerate_ckpt_noavx.sh - Genera los checkpoints SPEC aptos para gem5 SE
# (en el PC) y, con --upload, los deja listos en altek para run_mixed.sh /
# run_st_timing.sh / run_10M_suite.sh.
#
#   ./regenerate_ckpt_noavx.sh [--upload] [mcf|lbm|...|all]...
#
# "all" = todos los benchmarks rate con directorio de ejecucion preparado.
# Los benchmarks (directorio, binario, argumentos, instante del volcado) salen
# de benchmarks.sh, y la generacion la hace gen_ckpt.sh: ambos son la unica
# fuente de verdad, asi que un checkpoint sale igual lo genere este script,
# e2e_altek.sh o cualquier otro.
#
# --upload sube a altek, por cada checkpoint generado:
#   - el .ckpt (con .meta e .inspect) a CKPT_REMOTE_DIR (~/checkpoints),
#   - el directorio de ejecucion del benchmark a SPEC_REMOTE_DIR
#     (~/spec_cpu_2017/benchspec/CPU): sus entradas, que el ROI puede abrir,
#   - <ckpt>.remap: la traduccion SPEC_DIR del PC -> SPEC_REMOTE_DIR, que
#     run_mixed.sh y run_st_timing.sh pasan solos al loader.
# Despues, en altek:
#   launch_scripts/run_mixed.sh <tag> <insts> timing --pmu ~/checkpoints/dump_<b>.ckpt
#
# Dos condiciones para que un checkpoint sea simulable en gem5 SE:
#
#  1. El BINARIO del benchmark no debe contener AVX/AVX2/BMI2. gem5 SE no las
#     implementa. Se consigue compilando con specs/config/gem5_noavx.cfg
#     (generate_all_spec_checkpoints.sh --build-only). gen_ckpt.sh lo
#     comprueba y se niega a generar si las encuentra.
#
#  2. La GLIBC tampoco debe ejecutarlas. Su resolvedor IFUNC elige rutas AVX2
#     al arrancar (memcpy, strlen, memchr...). gen_ckpt.sh exporta
#     GLIBC_TUNABLES para que se quede en las rutas SSE2, que gem5 si
#     implementa.
#
# Variables: SPEC_DIR (.../benchspec/CPU; por defecto <repo>/specs/... si
# existe, si no ~/spec_cpu_2017/...), CKPT_DIR (destino local),
# RMC_REMOTE (altek1.gap.upv.es), CKPT_REMOTE_DIR, SPEC_REMOTE_DIR.
set -eu
HERE="$(dirname "${BASH_SOURCE[0]}")"
source "$HERE/_common.sh"
source "$HERE/benchmarks.sh"

UPLOAD=0
[ "${1:-}" = --upload ] && { UPLOAD=1; shift; }

SPEC_DIR="${SPEC_DIR:-$(default_spec_dir)}"
[ -d "$SPEC_DIR" ] || die "no existe SPEC_DIR=$SPEC_DIR"
# Ruta fisica: el cwd y los FDs del checkpoint la llevan sin enlaces
# simbolicos, y el .remap tiene que coincidir con ella
SPEC_DIR="$(cd "$SPEC_DIR" && pwd -P)"
mkdir -p "$CKPT_DIR"

WHAT=("$@")
[ ${#WHAT[@]} -eq 0 ] && WHAT=(all)
[ "${WHAT[0]}" = all ] && mapfile -t WHAT < <(bench_list)
[ ${#WHAT[@]} -gt 0 ] || die "no hay benchmarks rate preparados en $SPEC_DIR (generate_all_spec_checkpoints.sh --build-only)"

fails=0
DONE_CKPTS=(); DONE_RUNDIRS=()
for b in "${WHAT[@]}"; do
    bench_def "$b" || { echo "benchmark desconocido o sin preparar: $b ($SPEC_DIR)" >&2; fails=$((fails + 1)); continue; }
    bench_stdin_opt "$SPEC_DIR"
    if "$HERE/gen_ckpt.sh" -o "$CKPT_DIR/dump_${BENCH_CKPT}.ckpt" -C "$SPEC_DIR/$BENCH_RUNDIR" \
           -t "$BENCH_NS" ${BENCH_STDIN_OPT[@]+"${BENCH_STDIN_OPT[@]}"} \
           -- "./$BENCH_BIN" ${BENCH_ARGS[@]+"${BENCH_ARGS[@]}"}; then
        DONE_CKPTS+=("dump_${BENCH_CKPT}.ckpt"); DONE_RUNDIRS+=("$BENCH_RUNDIR")
    else
        fails=$((fails + 1))
    fi
done

if [ "$UPLOAD" = 1 ] && [ ${#DONE_CKPTS[@]} -gt 0 ]; then
    REMOTE="${RMC_REMOTE:-altek1.gap.upv.es}"
    SSH_OPTS=(-o ControlMaster=auto -o "ControlPath=/tmp/rmc-ssh-%C" -o ControlPersist=15m
              -o ConnectTimeout=20)
    RHOME=$(ssh "${SSH_OPTS[@]}" "$REMOTE" 'printf %s "$HOME"') || die "no hay acceso ssh a $REMOTE"
    CKPT_REMOTE_DIR="${CKPT_REMOTE_DIR:-$RHOME/checkpoints}"
    SPEC_REMOTE_DIR="${SPEC_REMOTE_DIR:-$RHOME/spec_cpu_2017/benchspec/CPU}"
    RSH="ssh ${SSH_OPTS[*]}"
    echo "=== Subiendo ${#DONE_CKPTS[@]} checkpoint(s) a $REMOTE:$CKPT_REMOTE_DIR ==="
    for i in "${!DONE_CKPTS[@]}"; do
        c=${DONE_CKPTS[$i]}; d=${DONE_RUNDIRS[$i]}
        printf '%s=%s\n' "$SPEC_DIR" "$SPEC_REMOTE_DIR" > "$CKPT_DIR/$c.remap"
        ssh "${SSH_OPTS[@]}" "$REMOTE" "mkdir -p '$CKPT_REMOTE_DIR' '$SPEC_REMOTE_DIR/$d'" \
            || die "no se pueden crear los directorios remotos"
        rsync -a -e "$RSH" "$SPEC_DIR/$d/" "$REMOTE:$SPEC_REMOTE_DIR/$d/" || die "subida de $d"
        rsync -a -e "$RSH" "$CKPT_DIR/$c" "$CKPT_DIR/$c.remap" "$CKPT_DIR/$c.meta" "$CKPT_DIR/$c.inspect" \
            "$REMOTE:$CKPT_REMOTE_DIR/" || die "subida de $c"
        echo "  $c  (+ $d)"
    done
    ssh "${SSH_OPTS[@]}" -O exit "$REMOTE" 2>/dev/null || true
    echo "=== En altek: launch_scripts/run_mixed.sh <tag> <insts> timing --pmu $CKPT_REMOTE_DIR/<ckpt> ==="
fi

[ "$fails" -eq 0 ] || die "$fails checkpoint(s) no se generaron"
echo "=== Listo: $CKPT_DIR ==="

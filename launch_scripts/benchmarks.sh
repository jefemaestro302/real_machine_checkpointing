# benchmarks.sh - Definicion UNICA de los benchmarks SPEC para generar
# checkpoints.
#
# La usan regenerate_ckpt_noavx.sh, generate_all_spec_checkpoints.sh y
# e2e_altek.sh; ningun otro script define comandos ni tiempos de disparo.
#
# Cualquier benchmark rate (NNN.<nombre>_r) con su directorio de ejecucion
# preparado (runcpu --action=setup --size=train) sirve sin tocar nada: el
# comando se lee del speccmds.cmd que deja runcpu en ese directorio (la
# primera invocacion si hay varias). Los casos de bench_def() solo fijan lo
# que se ha medido a mano (instante del volcado en la meseta de IPC,
# argumentos concretos).
#
# Solo rate (_r): los speed (_s) usan OpenMP y el checkpoint es de un hilo.
#
# Rutas relativas a SPEC_DIR (.../benchspec/CPU): el mismo arbol existe en el
# PC (<repo>/specs/benchspec/CPU) y en altek (~/spec_cpu_2017/benchspec/CPU).
#
# Variables:
#   SPEC_DIR          arbol SPEC (lo fija quien incluye este fichero)
#   RMC_SPEC_LABEL    label de gem5_noavx.cfg + bits (test_compilacion-m64)
#   RMC_SPEC_SIZE     carga de trabajo del directorio de ejecucion (train)
#   RMC_SPEC_NS       instante del volcado por defecto, en ns (2 s)
#
#   bench_list          nombres de los benchmarks rate con directorio de
#                       ejecucion preparado en SPEC_DIR (mcf, lbm, ...)
#   bench_missing       benchmarks rate de SPEC_DIR SIN directorio preparado
#   bench_def <nombre>  rellena (nombre: mcf, mcf_r o 505.mcf_r):
#     BENCH_CKPT    nombre del checkpoint (dump_<BENCH_CKPT>.ckpt)
#     BENCH_RUNDIR  directorio de ejecucion, relativo a SPEC_DIR
#     BENCH_BIN     binario (relativo a BENCH_RUNDIR)
#     BENCH_NS      instante del volcado (CKPT_AFTER_NS)
#     BENCH_ARGS    argumentos (array)
#     BENCH_STDIN   entrada estandar, relativa a BENCH_RUNDIR (vacio = /dev/null)
#   bench_stdin_opt <spec_dir>  deja en BENCH_STDIN_OPT las opciones -i de
#                   gen_ckpt.sh para el benchmark definido

RMC_SPEC_LABEL="${RMC_SPEC_LABEL:-test_compilacion-m64}"
RMC_SPEC_SIZE="${RMC_SPEC_SIZE:-train}"
RMC_SPEC_NS="${RMC_SPEC_NS:-2000000000}"

_bench_rundir_name() { echo "run_base_${RMC_SPEC_SIZE}_${RMC_SPEC_LABEL}.0000"; }

# 505.mcf_r -> mcf
_bench_short() { local b=${1##*/}; b=${b#*.}; echo "${b%_r}"; }

# nombre -> directorio del benchmark (505.mcf_r), vacio si no existe
_bench_base() {
    local n=${1#*.} d
    n=${n%_r}
    for d in "$SPEC_DIR"/[0-9][0-9][0-9]."$n"_r; do
        [ -d "$d" ] && { echo "${d##*/}"; return 0; }
    done
    return 1
}

bench_list() {
    local d
    for d in "$SPEC_DIR"/[0-9][0-9][0-9].*_r; do
        [ -f "$d/run/$(_bench_rundir_name)/speccmds.cmd" ] && _bench_short "$d"
    done
    return 0
}

bench_missing() {
    local d
    for d in "$SPEC_DIR"/[0-9][0-9][0-9].*_r; do
        [ -d "$d" ] || continue
        [ -f "$d/run/$(_bench_rundir_name)/speccmds.cmd" ] || _bench_short "$d"
    done
    return 0
}

# Primera invocacion de speccmds.cmd -> BENCH_BIN, BENCH_ARGS, BENCH_STDIN.
# Formato de specinvoke: lineas de directivas (-N, -C DIR, -E VAR VAL, -r...)
# y lineas de comando "[-i IN] [-o OUT] [-e ERR] EXE ARGS...". runcpu las
# escribe con rutas del sitio donde se preparo (p.ej. /spec2017/... dentro de
# Docker), asi que solo se usa el nombre del ejecutable: runcpu lo copia al
# directorio de ejecucion.
_bench_from_speccmds() {
    local f=$1 line i stdin t
    local -a tok
    [ -f "$f" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        read -r -a tok <<< "$line"
        [ ${#tok[@]} -eq 0 ] && continue
        case "${tok[0]}" in
            \#*|-N|-C|-E|-r|-u|-U|-S|-c|-b|-a|-w|-x|-p|-f|-k|-B|-Z) continue ;;
        esac
        i=0; stdin=""
        while [ $i -lt ${#tok[@]} ]; do
            case "${tok[$i]}" in
                -i) stdin=${tok[$((i + 1))]:-}; i=$((i + 2)) ;;
                -o|-e) i=$((i + 2)) ;;
                *) break ;;
            esac
        done
        [ $i -lt ${#tok[@]} ] || continue
        BENCH_BIN=${tok[$i]##*/}
        # specinvoke repite al final las redirecciones en sintaxis de shell
        # ("< in > out 2>> err"); ya van en -i/-o/-e y no son argumentos
        BENCH_ARGS=()
        for t in "${tok[@]:$((i + 1))}"; do
            case "$t" in '<'*|'>'*|[0-9]'>'*) break ;; esac
            BENCH_ARGS+=("$t")
        done
        BENCH_STDIN=${stdin##*/}
        return 0
    done < "$f"
    return 1
}

bench_def() {
    local base
    base=$(_bench_base "$1") || return 1
    BENCH_RUNDIR="$base/run/$(_bench_rundir_name)"
    BENCH_CKPT="$(_bench_short "$base")_r_noavx"
    BENCH_NS=$RMC_SPEC_NS
    BENCH_STDIN=""
    BENCH_BIN=""; BENCH_ARGS=()
    _bench_from_speccmds "$SPEC_DIR/$BENCH_RUNDIR/speccmds.cmd" || true

    # Valores medidos a mano (prevalecen sobre speccmds.cmd)
    case "$base" in
        505.mcf_r)
            BENCH_BIN=mcf_r_base.$RMC_SPEC_LABEL
            # 5 s: cae dentro de la meseta de IPC estable [1,1 s - 15,9 s]
            # medida con perf en maquina real (IPC nativo ~1,0, CV 12 %).
            # 10 ms (valor usado hasta 2026-09-01) capturaba el pico de
            # arranque/parseo de inp.in, no la fase de computo de mcf.
            BENCH_NS=5000000000
            BENCH_ARGS=(inp.in)
            ;;
        500.perlbench_r)
            BENCH_CKPT=perlbench_noavx          # nombre historico
            BENCH_BIN=perlbench_r_base.$RMC_SPEC_LABEL
            # 3 s: su meseta es practicamente toda la ejecucion (IPC ~3,5, CV 5 %)
            BENCH_NS=3000000000
            BENCH_ARGS=(-I./lib diffmail.pl 2 550 15 24 23 100)
            ;;
    esac
    [ -n "$BENCH_BIN" ]
}

# Opciones de entrada estandar para gen_ckpt.sh (array BENCH_STDIN_OPT)
bench_stdin_opt() {   # bench_stdin_opt <spec_dir>
    BENCH_STDIN_OPT=()
    [ -n "$BENCH_STDIN" ] && BENCH_STDIN_OPT=(-i "$1/$BENCH_RUNDIR/$BENCH_STDIN")
    return 0
}

# SPEC_DIR por defecto: el arbol local del repo si existe (PC), si no el del
# cluster.
default_spec_dir() {
    if [ -d "$REPO/specs/benchspec/CPU" ]; then
        echo "$REPO/specs/benchspec/CPU"
    else
        echo "$HOME/spec_cpu_2017/benchspec/CPU"
    fi
}

# benchmarks.sh - Tabla UNICA de benchmarks SPEC para generar checkpoints.
#
# La usan regenerate_ckpt_noavx.sh (generar en cualquier maquina) y
# e2e_altek.sh (prueba de extremo a extremo). Anadir un benchmark es anadir
# un caso aqui; ningun otro script define comandos ni tiempos de disparo.
#
# Rutas relativas a SPEC_DIR (.../benchspec/CPU): el mismo arbol existe en el
# PC (<repo>/specs/benchspec/CPU) y en altek (~/spec_cpu_2017/benchspec/CPU).
#
#   bench_def <nombre>  rellena:
#     BENCH_CKPT    nombre del checkpoint (dump_<BENCH_CKPT>.ckpt)
#     BENCH_RUNDIR  directorio de ejecucion, relativo a SPEC_DIR
#     BENCH_BIN     binario (relativo a BENCH_RUNDIR)
#     BENCH_NS      instante del volcado (CKPT_AFTER_NS), dentro de la fase
#                   estable de IPC medida con perf en maquina real
#     BENCH_ARGS    argumentos (array)
#     BENCH_STDIN   fichero de entrada estandar, relativo a BENCH_RUNDIR
#                   (vacio = /dev/null; p.ej. 503.bwaves_r lee de stdin)
#
#   bench_stdin_opt <spec_dir>  deja en BENCH_STDIN_OPT las opciones -i de
#                   gen_ckpt.sh para el benchmark definido

RMC_BENCHMARKS="mcf perlbench"

bench_def() {
    BENCH_STDIN=""
    case "$1" in
        mcf)
            BENCH_CKPT=mcf_r_noavx
            BENCH_RUNDIR=505.mcf_r/run/run_base_train_test_compilacion-m64.0000
            BENCH_BIN=mcf_r_base.test_compilacion-m64
            # 5 s: cae dentro de la meseta de IPC estable [1,1 s - 15,9 s]
            # medida con perf en maquina real (IPC nativo ~1,0, CV 12 %).
            # 10 ms (valor usado hasta 2026-09-01) capturaba el pico de
            # arranque/parseo de inp.in, no la fase de computo de mcf.
            BENCH_NS=5000000000
            BENCH_ARGS=(inp.in)
            ;;
        perlbench)
            BENCH_CKPT=perlbench_noavx
            BENCH_RUNDIR=500.perlbench_r/run/run_base_train_test_compilacion-m64.0000
            BENCH_BIN=perlbench_r_base.test_compilacion-m64
            # 3 s: su meseta es practicamente toda la ejecucion (IPC ~3,5, CV 5 %)
            BENCH_NS=3000000000
            BENCH_ARGS=(-I./lib diffmail.pl 2 550 15 24 23 100)
            ;;
        *)
            return 1
            ;;
    esac
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

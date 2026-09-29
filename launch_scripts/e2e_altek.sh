#!/bin/bash
# e2e_altek.sh - Prueba de extremo a extremo del flujo RMC en altek, lanzada
# desde el PC. Un solo comando:
#
#   launch_scripts/e2e_altek.sh [--spec mcf,perlbench|all] [opciones]
#
#   1. compila el repo en el PC (make)
#   2. genera los checkpoints con gen_ckpt.sh (el mismo camino que cualquier
#      otro checkpoint): las pruebas de test/ y, con --spec, los benchmarks
#      de benchmarks.sh. Un benchmark que no se pueda generar (AVX, termina
#      antes del volcado...) cuenta como prueba fallida y no para el resto.
#   3. sube a altek el repo compilado, los checkpoints y sus entradas
#   4. crea el trabajo SLURM (tests.tsv + run.env) y lo lanza con sbatch como
#      array: una tarea por prueba, hasta --parallel a la vez
#   5. espera a que termine, trae los resultados y devuelve el veredicto:
#        0 = todas las pruebas pasan, 1 = alguna falla,
#        2 = error de preparacion (compilacion, generacion, ssh, slurm)
#
# Pruebas (cada una restaura en gem5 y comprueba su salida, ver e2e_job.sh):
#   target_app     estatico no PIE, ckpt_dump(); checksum igual al nativo
#   static_malloc  estatico no PIE que hace crecer/recortar el heap (brk)
#   fd             FDs y remapeo de rutas (fichero movido de sitio)
#   redzone        volcado por senal en una funcion hoja (red zone)
#   signal_malloc  PIE, volcado por senal dentro de malloc; malloc tras restaurar
#   vdso           el reloj avanza tras restaurar (vDSO -> syscalls)
#   smt2           dos checkpoints (no PIE + PIE) en SMT-2 con O3 (y barrera con loader)
#   spec_<nombre>  (--spec) el benchmark llega a --spec-insts de ROI
#
# Opciones:
#   --spec LISTA        benchmarks (coma: mcf,lbm,...) o "all" = todos los
#                       rate con directorio de ejecucion preparado en SPEC_DIR
#   --spec-insts N      instrucciones de ROI por benchmark (10000000)
#   --restore M         auto|direct|loader (auto): direct = gem5 instala el
#                       checkpoint sin simular el loader (Process.rmcCheckpoint);
#                       auto = direct si el gem5 de altek lo soporta
#   --no-tests          solo SPEC, sin las pruebas de test/
#   --partition P       particion SLURM (compute)
#   --time T            limite de cada tarea (03:00:00)
#   --mem M             memoria de cada tarea (16G; "0" = no pedirla)
#   --parallel N        tareas a la vez (8)
#   --clean             borrar los checkpoints de altek si todo pasa
#   --attach ID         reengancharse a una ejecucion ya lanzada (si se corto
#                       la terminal): espera, trae resultados y da el veredicto
#
# Variables:
#   RMC_REMOTE        host ssh (altek1.gap.upv.es); "local" = esta maquina
#                     (para probar el orquestador donde hay sbatch y gem5)
#   RMC_REMOTE_BASE   directorio de las ejecuciones, relativo al $HOME remoto
#                     (TFM/rmc_e2e); cada ejecucion en <base>/<ID>
#   RMC_GEM5_REMOTE   gem5 en altek (~/gap_gem5/gem5/build/X86/gem5.opt)
#   SPEC_DIR          SPEC en el PC (<repo>/specs/benchspec/CPU)
#   SPEC_REMOTE_DIR   SPEC en altek (~/spec_cpu_2017/benchspec/CPU)
#   RMC_POLL          segundos entre consultas a SLURM (20)
#
# La conexion ssh se abre una vez y se reutiliza (ControlMaster): si pide
# contrasena, solo al principio.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/_common.sh"
source "$HERE/benchmarks.sh"

REMOTE="${RMC_REMOTE:-altek1.gap.upv.es}"
REMOTE_BASE="${RMC_REMOTE_BASE:-TFM/rmc_e2e}"
SPEC_DIR="${SPEC_DIR:-$REPO/specs/benchspec/CPU}"
POLL="${RMC_POLL:-20}"
PART="${RMC_PARTITION:-compute}"
TIME="03:00:00"
MEM="${RMC_MEM:-16G}"
PARALLEL="${RMC_MAX_PARALLEL:-8}"
SPEC_LIST=""; SPEC_INSTS=10000000; RUN_TESTS=1; CLEAN=0; ATTACH=""
RESTORE="${RMC_RESTORE:-auto}"

while [ $# -gt 0 ]; do
    case "$1" in
        --spec)       SPEC_LIST=$2; shift 2 ;;
        --spec-insts) SPEC_INSTS=$2; shift 2 ;;
        --restore)    RESTORE=$2; shift 2 ;;
        --no-tests)   RUN_TESTS=0; shift ;;
        --partition)  PART=$2; shift 2 ;;
        --time)       TIME=$2; shift 2 ;;
        --mem)        MEM=$2; shift 2 ;;
        --parallel)   PARALLEL=$2; shift 2 ;;
        --clean)      CLEAN=1; shift ;;
        --attach)     ATTACH=$2; shift 2 ;;
        -h|--help)    sed -n '2,/^set -uo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
        *) echo "opcion desconocida: $1 (--help)" >&2; exit 2 ;;
    esac
done
# Ruta fisica: el cwd y los FDs del checkpoint la llevan sin enlaces
# simbolicos, y el remapeo SPEC_DIR=SPEC_REMOTE_DIR tiene que coincidir
[ -d "$SPEC_DIR" ] && SPEC_DIR="$(cd "$SPEC_DIR" && pwd -P)"
SPEC_MISSING=""
if [ "$SPEC_LIST" = all ]; then
    SPEC_LIST="$(bench_list | paste -sd, -)"
    SPEC_MISSING="$(bench_missing | paste -sd' ' -)"
    [ -n "$SPEC_LIST" ] || { echo "RESULTADO: ERROR DE PREPARACION: no hay benchmarks rate preparados en $SPEC_DIR (generate_all_spec_checkpoints.sh --build-only)" >&2; exit 2; }
fi

# ---- Utilidades --------------------------------------------------------------
T0=$(date +%s)
step() { echo ""; echo "==> [$(( $(date +%s) - T0 ))s] $*"; }
infra_fail() { echo ""; echo "RESULTADO: ERROR DE PREPARACION: $*" >&2; exit 2; }

SSH_OPTS=(-o ControlMaster=auto -o "ControlPath=/tmp/rmc-ssh-%C" -o ControlPersist=15m
          -o ConnectTimeout=20 -o ServerAliveInterval=30)
remote() {                      # remote "comando"
    if [ "$REMOTE" = local ]; then bash -c "$1"; else ssh "${SSH_OPTS[@]}" "$REMOTE" "$1"; fi
}
push() {                        # push ORIGEN DESTINO_REMOTO [opciones rsync]
    local src=$1 dst=$2; shift 2
    if [ "$REMOTE" = local ]; then rsync -a "$@" "$src" "$dst"
    else rsync -a -e "ssh ${SSH_OPTS[*]}" "$@" "$src" "$REMOTE:$dst"; fi
}
pull() {                        # pull ORIGEN_REMOTO DESTINO [opciones rsync]
    local src=$1 dst=$2; shift 2
    if [ "$REMOTE" = local ]; then rsync -a "$@" "$src" "$dst"
    else rsync -a -e "ssh ${SSH_OPTS[*]}" "$@" "$REMOTE:$src" "$dst"; fi
}
close_ssh() { [ "$REMOTE" = local ] || ssh "${SSH_OPTS[@]}" -O exit "$REMOTE" 2>/dev/null; }

# ---- Espera y veredicto (tambien para --attach) ----------------------------
JOB=""
on_interrupt() {
    echo ""
    if [ -n "$JOB" ]; then
        echo "Interrumpido: el trabajo $JOB sigue en altek."
        echo "  reengancharse:  $0 --attach $ID"
        echo "  cancelarlo:     ssh $REMOTE scancel $JOB"
    fi
    close_ssh; exit 130
}
trap on_interrupt INT TERM

wait_and_verdict() {
    step "Esperando al trabajo $JOB (particion $PART; consulta cada ${POLL}s)"
    local last="" st misses=0
    while :; do
        # Array: una linea por tarea (o por bloque de pendientes); se muestra
        # el recuento por estado
        st=$(remote "squeue -h -j $JOB -o %T 2>&1")
        if [ $? -ne 0 ]; then
            if [[ "$st" == *"Invalid job id"* ]]; then break; fi
            misses=$((misses + 1))
            [ "$misses" -gt 15 ] && infra_fail "no se puede consultar SLURM ($st)"
            sleep "$POLL"; continue
        fi
        misses=0
        [ -z "$st" ] && break
        st=$(sort <<< "$st" | uniq -c | awk '{printf "%s%s=%s", (NR>1?" ":""), $2, $1}')
        if [ "$st" != "$last" ]; then
            echo "    [$(( $(date +%s) - T0 ))s] $JOB: $st"; last=$st
        fi
        sleep "$POLL"
    done
    local acct
    acct=$(remote "sacct -j $JOB -X -n -P -o State 2>/dev/null" | sort | uniq -c \
           | awk '{printf "%s%s=%s", (NR>1?" ":""), $2, $1}')
    echo "    trabajo terminado: ${acct:-estado no disponible (sacct)}"

    # Resumen en altek a partir del resultado de cada tarea
    remote "bash '$REMOTE_RUN/repo/launch_scripts/e2e_job.sh' --summary '$REMOTE_RUN' >/dev/null 2>&1"

    step "Trayendo resultados a $LOCAL_RUN/results"
    mkdir -p "$LOCAL_RUN/results"
    pull "$REMOTE_RUN/results/" "$LOCAL_RUN/results/" --exclude '*.csv' \
        || echo "AVISO: no se pudieron traer todos los resultados"

    local sum="$LOCAL_RUN/results/summary.txt"
    echo ""
    if [ ! -s "$sum" ]; then
        echo "El trabajo no dejo resumen. Salida de SLURM:"
        tail -n 30 "$LOCAL_RUN"/results/slurm-*.out 2>/dev/null | sed 's/^/  | /'
        echo ""
        echo "RESULTADO: FALLO (el trabajo no llego a ejecutar las pruebas; ${acct:-})"
        echo "  remoto: $REMOTE:$REMOTE_RUN"
        close_ssh; exit 1
    fi
    cat "$sum"
    echo ""
    if grep -qE "^RESULT: [1-9][0-9]* passed, 0 failed" "$sum"; then
        [ "$CLEAN" = 1 ] && remote "rm -rf '$REMOTE_RUN/ckpt'" && echo "(checkpoints borrados de altek)"
        echo "RESULTADO: EXITO  (logs: $LOCAL_RUN/results)"
        close_ssh; exit 0
    fi
    echo "RESULTADO: FALLO  (logs: $LOCAL_RUN/results, remoto: $REMOTE:$REMOTE_RUN)"
    close_ssh; exit 1
}

# ---- --attach -----------------------------------------------------------------
if [ -n "$ATTACH" ]; then
    ID=$ATTACH
    LOCAL_RUN="$REPO/e2e_runs/$ID"
    [ -f "$LOCAL_RUN/state.env" ] || infra_fail "no existe $LOCAL_RUN/state.env"
    # shellcheck disable=SC1091
    source "$LOCAL_RUN/state.env"
    wait_and_verdict
fi

# ---- 0. Comprobaciones --------------------------------------------------------
ID="$(date +%Y%m%d_%H%M%S)"
LOCAL_RUN="$REPO/e2e_runs/$ID"
WORK="$LOCAL_RUN/work"; CK="$LOCAL_RUN/ckpt"
mkdir -p "$WORK" "$CK" "$LOCAL_RUN/results"
[[ "$LOCAL_RUN$SPEC_DIR" == *" "* ]] && infra_fail "las rutas con espacios no estan soportadas ($LOCAL_RUN)"
[ "$RUN_TESTS" = 1 ] || [ -n "$SPEC_LIST" ] || infra_fail "nada que probar (--no-tests sin --spec)"

step "Comprobaciones (PC y $REMOTE)"
for t in gcc make python3 rsync setarch readelf objdump; do
    command -v "$t" >/dev/null || infra_fail "falta '$t' en el PC"
done
[ "$REMOTE" = local ] || command -v ssh >/dev/null || infra_fail "falta ssh"
setarch -R true 2>/dev/null || infra_fail "setarch -R no funciona en el PC (¿Docker?)"
RHOME=$(remote 'printf %s "$HOME"') || infra_fail "no hay acceso ssh a $REMOTE"
REMOTE_RUN="$RHOME/$REMOTE_BASE/$ID"
GEM5_REMOTE="${RMC_GEM5_REMOTE:-$RHOME/gap_gem5/gem5/build/X86/gem5.opt}"
SPEC_REMOTE_DIR="${SPEC_REMOTE_DIR:-$RHOME/spec_cpu_2017/benchspec/CPU}"
remote "test -x '$GEM5_REMOTE'" || infra_fail "no existe gem5 en $REMOTE:$GEM5_REMOTE (RMC_GEM5_REMOTE)"
remote "command -v sbatch >/dev/null && command -v squeue >/dev/null && command -v rsync >/dev/null" \
    || infra_fail "faltan sbatch/squeue/rsync en $REMOTE"
echo "    PC:     $LOCAL_RUN"
echo "    altek:  $REMOTE:$REMOTE_RUN"
echo "    gem5:   $GEM5_REMOTE"

# ---- 1. Compilacion -------------------------------------------------------------
step "Compilando en el PC"
make -C "$REPO" > "$LOCAL_RUN/make.log" 2>&1 || { tail -20 "$LOCAL_RUN/make.log"; infra_fail "make fallo"; }
CFL="-O2 -mno-avx -mno-avx2 -mno-sse4.1 -mno-sse4.2"
build() { gcc "$@" 2>>"$LOCAL_RUN/make.log" || infra_fail "no compila: $*"; }

# ---- 2. Checkpoints ---------------------------------------------------------------
TESTS="$LOCAL_RUN/tests.tsv"
: > "$TESTS"
add_test() {     # nombre modo ckpts maxinsts regex_esperada minimo regex_fallo timeout
    local f out=()
    for f in "$@"; do out+=("${f:--}"); done   # campo vacio -> "-" (read fusiona tabuladores)
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${out[@]}" >> "$TESTS"
}
GEN="$HERE/gen_ckpt.sh"
REMAPS=()

if [ "$RUN_TESTS" = 1 ]; then
    step "Generando los checkpoints de prueba"
    build $CFL -fPIE -pie -o "$WORK/test_redzone"       "$REPO/test/test_redzone.c"
    build $CFL -fPIE -pie -o "$WORK/test_signal_malloc" "$REPO/test/test_signal_malloc.c"
    build -O1 -mno-avx -fPIE -pie -o "$WORK/test_vdso"  "$REPO/test/test_vdso.c"
    build $CFL -static -no-pie -fno-stack-protector -o "$WORK/test_static_malloc" \
        "$REPO/test/test_static_malloc.c" "$REPO/src/dumper.c" "$REPO/src/dumper_asm.S"
    build $CFL -static -no-pie -fno-stack-protector -fno-builtin -o "$WORK/test_fd" \
        "$REPO/test/test_fd.c" "$REPO/src/dumper.c" "$REPO/src/dumper_asm.S"

    "$GEN" -w -C "$WORK" -o "$CK/target_app.ckpt" -- "$REPO/build/target_app" "$CK/target_app.ckpt" \
        || infra_fail "generacion de target_app"
    CHK=$(grep -o 'checksum=0x[0-9a-f]*' "$CK/target_app.ckpt.log" | tail -1)
    [ -n "$CHK" ] || infra_fail "target_app no imprimio su checksum nativo"

    "$GEN" -w -C "$WORK" -o "$CK/test_static_malloc.ckpt" -- ./test_static_malloc "$CK/test_static_malloc.ckpt" \
        || infra_fail "generacion de test_static_malloc"

    mkdir -p "$WORK/fd"
    printf 1234567890 > "$WORK/fd/input1.txt"
    "$GEN" -w -C "$WORK/fd" -o "$CK/test_fd.ckpt" -- ../test_fd "$WORK/fd/input1.txt" "$WORK/fd/output.txt" "$CK/test_fd.ckpt" \
        || infra_fail "generacion de test_fd"
    # La entrada "se mueve" de sitio: el loader la encuentra por el remapeo
    mkdir -p "$WORK/fd/new_dir"; mv "$WORK/fd/input1.txt" "$WORK/fd/new_dir/"; rm -f "$WORK/fd/output.txt"
    REMAPS+=("$WORK/fd/input1.txt=$REMOTE_RUN/work/fd/new_dir/input1.txt")

    "$GEN" -C "$WORK" -t 300000000 -o "$CK/test_redzone.ckpt"       -- ./test_redzone       || infra_fail "generacion de test_redzone"
    "$GEN" -C "$WORK" -t 200000000 -o "$CK/test_signal_malloc.ckpt" -- ./test_signal_malloc || infra_fail "generacion de test_signal_malloc"
    "$GEN" -C "$WORK" -t 300000000 -o "$CK/test_vdso.ckpt"          -- ./test_vdso          || infra_fail "generacion de test_vdso"

    add_test target_app    st  ckpt/target_app.ckpt         50000000   "$CHK"                           1 ""                 1800
    add_test static_malloc st  ckpt/test_static_malloc.ckpt 2000000000 "STATIC MALLOC OK"               1 ""                 3600
    add_test fd            st  ckpt/test_fd.ckpt            50000000   "Restored from dump!|read '67890'" 2 "Dump FAILED"    1800
    add_test redzone       st  ckpt/test_redzone.ckpt       150000000  "REDZONE round [0-9]+ ok"        2 "REDZONE CORRUPT"  3600
    add_test signal_malloc st  ckpt/test_signal_malloc.ckpt 150000000  "MALLOC chunk [0-9]+ ok"         2 ""                 3600
    add_test vdso          st  ckpt/test_vdso.ckpt          150000000  "CLOCK round [0-9]+ ok"          2 "CLOCK STUCK"      3600
    # Barrera en cada loader, o en restauracion directa cada proceso instalado sin loader
    add_test smt2          smt ckpt/test_static_malloc.ckpt,ckpt/test_signal_malloc.ckpt 200000 "SMT barrier passed|-> directa " 2 "" 3600
fi
REMAPS+=("$WORK=$REMOTE_RUN/work")

SPEC_DIRS=()
if [ -n "$SPEC_LIST" ]; then
    step "Generando los checkpoints SPEC: $SPEC_LIST"
    [ -n "$SPEC_MISSING" ] && echo "    sin directorio de ejecucion preparado (no entran): $SPEC_MISSING"
    IFS=',' read -r -a benches <<< "$SPEC_LIST"
    ngen=0
    for b in "${benches[@]}"; do
        b=${b#*.}; b=${b%_r}
        [ -d "$SPEC_DIR" ] || infra_fail "no existe SPEC_DIR=$SPEC_DIR"
        bench_def "$b" || infra_fail "benchmark desconocido o sin preparar: $b (en $SPEC_DIR/NNN.${b}_r/run/ falta $(_bench_rundir_name)/speccmds.cmd)"
        bench_stdin_opt "$SPEC_DIR"
        # Un fallo de generacion no para los demas: queda como prueba fallida
        err="$CK/gen_$b.err"
        if "$GEN" -C "$SPEC_DIR/$BENCH_RUNDIR" -t "$BENCH_NS" ${BENCH_STDIN_OPT[@]+"${BENCH_STDIN_OPT[@]}"} \
               -o "$CK/dump_${BENCH_CKPT}.ckpt" -- "./$BENCH_BIN" ${BENCH_ARGS[@]+"${BENCH_ARGS[@]}"} 2> "$err"; then
            cat "$err" >&2
            add_test "spec_$b" st "ckpt/dump_${BENCH_CKPT}.ckpt" "$SPEC_INSTS" "ROI terminado: 'ROI: " 1 "" 7200
            SPEC_DIRS+=("$BENCH_RUNDIR")
            ngen=$((ngen + 1))
        else
            cat "$err" >&2
            why=$(grep -E 'FALLO|ERROR|error|no se' "$err" | head -1 | tr '\t' ' ')
            add_test "spec_$b" genfail - - "${why:-ver ckpt/gen_$b.err}" - - -
        fi
    done
    echo "    SPEC: $ngen de ${#benches[@]} checkpoints generados"
    REMAPS+=("$SPEC_DIR=$SPEC_REMOTE_DIR")
fi

{
    printf 'GEM5_BIN=%q\n' "$GEM5_REMOTE"
    printf 'REMAPS=%q\n'   "${REMAPS[*]}"
    printf 'RESTORE=%q\n'  "$RESTORE"
} > "$LOCAL_RUN/run.env"

# ---- 3. Subida ---------------------------------------------------------------------
step "Subiendo a $REMOTE"
remote "mkdir -p '$REMOTE_RUN/repo' '$REMOTE_RUN/ckpt' '$REMOTE_RUN/work' '$REMOTE_RUN/results'" \
    || infra_fail "no se puede crear $REMOTE_RUN"
# Repo: ficheros versionados (y nuevos no ignorados) que existen + build/
# compilado en el PC
( cd "$REPO" && git ls-files -co --exclude-standard -z \
    | while IFS= read -r -d '' f; do if [ -e "$f" ]; then printf '%s\0' "$f"; fi; done ) \
    > "$LOCAL_RUN/files.lst" || infra_fail "git ls-files"
push "$REPO/" "$REMOTE_RUN/repo/" --from0 --files-from="$LOCAL_RUN/files.lst" || infra_fail "subida del repo"
push "$REPO/build/" "$REMOTE_RUN/repo/build/" --exclude '*.o'                 || infra_fail "subida de build/"
push "$CK/" "$REMOTE_RUN/ckpt/"                                                || infra_fail "subida de checkpoints"
push "$WORK/" "$REMOTE_RUN/work/"                                              || infra_fail "subida de entradas"
push "$TESTS" "$REMOTE_RUN/tests.tsv"                                          || infra_fail "subida de tests.tsv"
push "$LOCAL_RUN/run.env" "$REMOTE_RUN/run.env"                                || infra_fail "subida de run.env"
for d in ${SPEC_DIRS[@]+"${SPEC_DIRS[@]}"}; do
    remote "mkdir -p '$SPEC_REMOTE_DIR/$d'" || infra_fail "mkdir $SPEC_REMOTE_DIR/$d"
    push "$SPEC_DIR/$d/" "$SPEC_REMOTE_DIR/$d/" || infra_fail "subida de $d"
done
echo "    $(du -sh "$CK" | cut -f1) de checkpoints, $(wc -l < "$TESTS") pruebas"

# ---- 4. Trabajo SLURM ----------------------------------------------------------------
NTESTS=$(wc -l < "$TESTS")
MEMOPT=""; [ "$MEM" != 0 ] && MEMOPT="--mem=$MEM"
step "Lanzando el trabajo SLURM ($NTESTS tareas, $PARALLEL a la vez)"
SB=$(remote "sbatch --parsable -J rmc_e2e -p '$PART' -t '$TIME' -c 1 $MEMOPT \
        --array=1-$NTESTS%$PARALLEL \
        -D '$REMOTE_RUN' -o '$REMOTE_RUN/results/slurm-%A_%a.out' \
        '$REMOTE_RUN/repo/launch_scripts/e2e_job.sh' '$REMOTE_RUN' 2>&1") \
    || infra_fail "sbatch fallo: $SB"
# --parsable: "ID" o "ID;cluster" (puede venir tras avisos en stderr)
JOB=$(grep -oE '^[0-9]+' <<< "$SB" | tail -1)
[ -n "$JOB" ] || infra_fail "sbatch devolvio '$SB'"
{
    printf 'JOB=%q\nREMOTE=%q\nREMOTE_RUN=%q\nPART=%q\nCLEAN=%q\n' \
        "$JOB" "$REMOTE" "$REMOTE_RUN" "$PART" "$CLEAN"
} > "$LOCAL_RUN/state.env"
echo "    trabajo $JOB  (reengancharse si se corta: $0 --attach $ID)"

# ---- 5. Espera y veredicto -------------------------------------------------------------
wait_and_verdict

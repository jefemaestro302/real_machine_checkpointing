#!/bin/bash
# e2e_job.sh - Trabajo SLURM de la prueba de extremo a extremo.
#
# Lo crea y lo lanza launch_scripts/e2e_altek.sh desde el PC; no hace falta
# lanzarlo a mano:
#
#   sbatch ... e2e_job.sh RUN_DIR
#
# RUN_DIR contiene repo/ (el repo compilado en el PC), ckpt/, work/,
# run.env (GEM5_BIN, REMAPS) y tests.tsv, una prueba por linea con campos
# separados por tabuladores:
#
#   nombre  modo(st|smt)  ckpts(a,b)  maxinsts  regex_esperada  minimo  regex_fallo  timeout_s
#
# Un campo vacio se escribe "-" (read fusiona tabuladores consecutivos).
#
# Cada prueba lanza gem5 y pasa si:
#   - gem5 termina con codigo 0 y antes del timeout,
#   - el loader llega a la frontera del ROI (m5_exit) en todos los procesos,
#   - no aparece ningun error (panic/fatal de gem5, FATAL del loader,
#     corrupcion de malloc, violacion de segmento, regex_fallo),
#   - regex_esperada aparece al menos `minimo` veces en la salida.
#
# Resultados: RUN_DIR/results/<prueba>/{gem5.log,m5out/} y
# RUN_DIR/results/summary.txt (lo que e2e_altek.sh trae y muestra).
set -u
RUN="${1:?uso: e2e_job.sh RUN_DIR}"
REPO="$RUN/repo"
RES="$RUN/results"
mkdir -p "$RES"
# shellcheck disable=SC1091
source "$RUN/run.env"
SUM="$RES/summary.txt"
: > "$SUM"

say() { echo "$*" | tee -a "$SUM"; }
say "rmc e2e: job ${SLURM_JOB_ID:-local} en $(hostname) $(date -Is)"
say "gem5: $GEM5_BIN"
say "remapeos: ${REMAPS:-(ninguno)}"
say ""

GENERIC_FAIL='^(panic|fatal):|\[loader\] FATAL|Segmentation fault|double free|corrupted|malloc\(\)|Aborted|Illegal instruction'
pass=0; fail=0

while IFS=$'\t' read -r name mode ckpts maxinsts expect min failre tmo; do
    [ -z "${name:-}" ] && continue
    [[ "$name" == \#* ]] && continue
    [ "$failre" = - ] && failre=""
    d="$RES/$name"
    rm -rf "$d"; mkdir -p "$d"
    IFS=',' read -r -a cks <<< "$ckpts"
    for i in "${!cks[@]}"; do cks[$i]="$RUN/${cks[$i]}"; done

    case "$mode" in
        st)
            cmd=("$GEM5_BIN" --outdir="$d/m5out" "$REPO/gem5_configs/x86_st_timing.py"
                 --cmd="$REPO/build/loader" --options="${cks[0]} ${REMAPS:-}"
                 --cpu=atomic --maxinsts="$maxinsts")
            need_exits=1
            ;;
        smt)
            cmd=("$GEM5_BIN" --outdir="$d/m5out" "$REPO/gem5_configs/x86_mixed.py"
                 --loader="$REPO/build/loader" --ckpts "${cks[@]}"
                 --load-cpu=timing --maxinsts="$maxinsts" --loader-opts="${REMAPS:-}")
            need_exits=${#cks[@]}
            ;;
        *)
            say "FAIL  $name: modo desconocido '$mode'"; fail=$((fail + 1)); continue ;;
    esac

    t0=$(date +%s)
    ( cd "$d" && timeout "$tmo" "${cmd[@]}" ) > "$d/gem5.log" 2>&1
    rc=$?
    secs=$(( $(date +%s) - t0 ))
    log="$d/gem5.log"

    reason=""
    if [ "$rc" -eq 124 ]; then
        reason="timeout (${tmo}s)"
    else
        if [ "$mode" = st ]; then
            grep -q "Loader terminado: 'm5_exit instruction encountered'" "$log" && exits=1 || exits=0
        else
            exits=$(grep -c "\] listo en tick" "$log")
        fi
        bad=$(grep -m1 -E "$GENERIC_FAIL" "$log")
        [ -z "$bad" ] && [ -n "$failre" ] && bad=$(grep -m1 -E "$failre" "$log")
        got=$(grep -cE "$expect" "$log")
        if [ "$exits" -lt "$need_exits" ]; then
            reason="el loader no llego al ROI ($exits/$need_exits m5_exit)"
            loaderr=$(grep -m1 -E "\[loader\] (FATAL|WARNING)" "$log")
            [ -n "$loaderr" ] && reason="$reason: $loaderr"
        elif [ -n "$bad" ]; then
            reason="error en la salida: $bad"
        elif [ "$rc" -ne 0 ]; then
            reason="gem5 termino con codigo $rc"
        elif [ "$got" -lt "$min" ]; then
            reason="'$expect' aparece $got veces (minimo $min)"
        fi
    fi

    roi=$(grep -oE "Instrucciones de ROI ejecutadas: [0-9]+|hilo [0-9]+ \([^)]*\): [0-9]+ instrucciones de ROI" "$log" | tr '\n' ' ')
    if [ -z "$reason" ]; then
        say "PASS  $name (${secs}s) ${roi}"
        pass=$((pass + 1))
    else
        say "FAIL  $name (${secs}s): $reason"
        say "      log: $log"
        tail -n 8 "$log" | sed 's/^/      | /' >> "$SUM"
        fail=$((fail + 1))
    fi
done < "$RUN/tests.tsv"

say ""
say "RESULT: $pass passed, $fail failed"
touch "$RES/DONE"
[ "$fail" -eq 0 ]

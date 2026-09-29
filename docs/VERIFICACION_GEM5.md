# Verificacion de los arreglos en gem5

Complemento de [`BUG_FIXES.md`](BUG_FIXES.md). Las pruebas nativas
(`test/run_native_tests.sh`) cubren lo que se reproduce en el host; lo que
solo se ve dentro de gem5 SE (program break, vDSO, mapeo del `.ckpt`, FDs y
cwd, SMT, frontera del ROI) lo cubre la prueba de extremo a extremo.

## 1. Prueba automatica: `launch_scripts/e2e_altek.sh`

Se lanza desde el PC y devuelve el veredicto en la terminal:

```bash
launch_scripts/e2e_altek.sh                           # pruebas de test/
launch_scripts/e2e_altek.sh --spec mcf,perlbench      # + benchmarks SPEC
launch_scripts/e2e_altek.sh --spec all --no-tests     # solo SPEC
```

Que hace:

1. `make` en el PC.
2. Genera los checkpoints con `launch_scripts/gen_ckpt.sh` (el mismo camino
   que cualquier otro checkpoint: sin ASLR, `GLIBC_TUNABLES` sin AVX,
   `LD_BIND_NOW=1`, `libckpt.so`, espera al volcado completo, validacion).
3. Sube a `altek:~/TFM/rmc_e2e/<ID>/` el repo compilado, los checkpoints y sus
   entradas (y con `--spec`, los directorios de ejecucion de SPEC).
4. Crea `tests.tsv` y `run.env` y lanza `launch_scripts/e2e_job.sh` con
   `sbatch` (particion `compute`, `--partition`/`--time` para cambiarlo).
5. Consulta SLURM hasta que termina, trae `results/` a `e2e_runs/<ID>/` y
   muestra el resumen.

Codigo de salida: **0** todo pasa, **1** alguna prueba falla, **2** error de
preparacion (compilacion, generacion, ssh o SLURM). Si se corta la terminal,
el trabajo sigue: `launch_scripts/e2e_altek.sh --attach <ID>` se reengancha y
da el veredicto. Con Ctrl-C se muestra como cancelarlo.

Requisitos en el PC: Linux x86-64 con `gcc`, `make`, `python3`, `rsync`,
`ssh` a altek (con clave, o se pide la contrasena una vez: la conexion se
reutiliza) y `setarch -R` operativo (fuera de Docker). Para `--spec`, el arbol
SPEC compilado en `<repo>/specs/benchspec/CPU` (`SPEC_DIR`).

Variables utiles: `RMC_REMOTE` (host), `RMC_GEM5_REMOTE` (gem5 en altek, por
defecto `~/gap_gem5/gem5/build/X86/gem5.opt`), `SPEC_REMOTE_DIR`
(`~/spec_cpu_2017/benchspec/CPU`), `RMC_POLL`.

### Que comprueba cada prueba

Cada prueba restaura su checkpoint en gem5 y pasa si gem5 termina bien, el
loader llega al `m5_exit` (en todos los procesos; con `--restore direct`, gem5
instala los checkpoints en `initState`), no aparece ningun error
(`panic`/`fatal` de gem5, `FATAL` del loader, corrupcion de malloc, violacion
de segmento) y la salida esperada aparece. `--restore auto|direct|loader`
elige el modo (ver [`RESTAURACION_DIRECTA.md`](RESTAURACION_DIRECTA.md)); en
directo no hay loader, asi que las pruebas comprueban que el mismo estado
restaurado por gem5 da la misma salida:

| Prueba | Checkpoint | Pasa si | Bugs que cubre |
|---|---|---|---|
| `target_app` | estatico no PIE, `ckpt_dump()` | mismo `checksum=0x...` que en nativo | 1, 3, 5, 7, 8 |
| `static_malloc` | estatico no PIE, heap por debajo del loader | `STATIC MALLOC OK`: el heap crece y se recorta tras restaurar | 4 (reduccion del break desde el trampolin) |
| `fd` | estatico, fichero de entrada movido de sitio | `Restored from dump!` y lectura de `67890` por el remapeo | 5 (rax=1), 9 |
| `redzone` | PIE, volcado por senal en una funcion hoja | >= 2 `REDZONE round N ok` y ningun `REDZONE CORRUPT` | 1 |
| `signal_malloc` | PIE, volcado por senal dentro de malloc | >= 2 `MALLOC chunk N ok` sin abortos de glibc | 2, 4 (ampliacion del break, `loader_pie`) |
| `vdso` | PIE | >= 2 `CLOCK round N ok` y ningun `CLOCK STUCK` | 11 |
| `smt2` | `static_malloc` + `signal_malloc` en SMT-2 (O3) | loader: `SMT barrier passed` en los dos procesos, cada uno con su loader; directa: los dos procesos instalados (`-> directa`) y el ROI en O3 sin errores | 4, 10 |
| `spec_<b>` | cada benchmark rate preparado (`--spec all`), comando de su `speccmds.cmd` | llega a `--spec-insts` instrucciones de ROI | todo el flujo, cwd y remapeo de SPEC |

Las pruebas que no terminan solas (`redzone`, `signal_malloc`, `vdso`) se
limitan con `--maxinsts` e imprimen una linea por ronda: lo que se comprueba es
que el ROI avanza sin error.

Resultados: `e2e_runs/<ID>/results/summary.txt` y, por prueba,
`results/<prueba>/gem5.log` y `m5out/`. En altek quedan en
`~/TFM/rmc_e2e/<ID>/` (`--clean` borra los checkpoints si todo pasa).

## 2. Comprobaciones manuales

Para investigar un fallo concreto. Desde el repo en altek:

```bash
R=~/TFM/repositories/real_machine_checkpointing; source $R/launch_scripts/_common.sh
W=$HOME/TFM/rmc_checks; mkdir -p $W; cd $W
G=$R/launch_scripts/gen_ckpt.sh
gem5dbg() {   # gem5dbg <ckpt> <maxinsts>: CPU atomic + traza de syscalls
    $GEM5_BIN --outdir=$W/dbg --debug-flags=SyscallVerbose --debug-file=sys.trace \
        $R/gem5_configs/x86_st_timing.py --cmd=$R/build/loader \
        --options="$1" --cpu=atomic --maxinsts=$2
}
```

(Los checkpoints se pueden generar en altek o traer los de una ejecucion de
`e2e_altek.sh`: estan en `~/TFM/rmc_e2e/<ID>/ckpt/`, con su `.meta`.)

Cada ejecucion imprime `**** Loader: .../loader_pie   cwd: ... ****`: la
eleccion automatica de loader y el directorio de trabajo restaurado
(`gem5_configs/rmc_common.py`). `python3 $R/tools/ckpt_inspect.py X.ckpt`
muestra la version, el `heap_end`, el loader recomendado y el `cwd`.

### Program break (bug 4)

```bash
gcc -O2 -fPIE -pie -mno-avx -o test_signal_malloc $R/test/test_signal_malloc.c
$G -t 200000000 -o $W/m.ckpt -- ./test_signal_malloc
gem5dbg $W/m.ckpt 150000000 | grep -E "MALLOC|FATAL"
grep -E "brk" $W/dbg/sys.trace | head
```
- PIE (`loader_pie`): el primer `brk` (del loader, antes del `m5_exit`) devuelve
  el `heap_end` del checkpoint; los `brk` del ROI crecen desde ese valor.
  Sin el arreglo devolvian el break del loader y glibc abortaba en el primer
  recorte del heap (`double free or corruption (out)`).
- No PIE (`test/test_static_malloc.c`, `loader`): un `brk(heap_end)` emitido
  desde el trampolin justo antes del `m5_exit`; sin el arreglo gem5 trataba el
  crecimiento como una reduccion y el ROI fallaba al tocar el heap nuevo.
- Si el loader imprime `target heap far above/below the loader break`, se esta
  usando el loader equivocado para ese checkpoint.

### vDSO (bug 11)

En `sys.trace` aparecen syscalls `clock_gettime`/`gettimeofday` durante el ROI
y el loader imprime `[vdso] entry points redirected to syscalls: 0xb` (> 0).
Antes se ejecutaba el vDSO del host sobre una `[vvar]` congelada: reloj parado.

### Mapeo del `.ckpt` (bug 3)

En `sys.trace`, el `mmap` del fichero del checkpoint devuelve una direccion
`>= 0x100000000000` y, justo antes del `m5_exit`, hay un `munmap` de ella.

### SMT (bug 10)

En `results/smt2/gem5.log`, las lineas `[loader k/2] listo ... insts=[a, b]`:
lo que avanza cada hilo entre el primer y el ultimo `m5_exit` es ROI en la
CPU simple; con la barrera son miles de instrucciones, sin ella todo lo que
tardara el otro loader en restaurar.

### Checkpoints truncados (bug 6)

```bash
head -c 3000000 $W/m.ckpt > $W/trunc.ckpt
python3 $R/tools/ckpt_inspect.py $W/trunc.ckpt | grep '!!'
gem5dbg $W/trunc.ckpt 1000 | grep FATAL      # Corrupt or truncated checkpoint
```

### SPEC

```bash
$R/launch_scripts/regenerate_ckpt_noavx.sh all        # formato v2 (los v1 se rechazan)
$R/launch_scripts/run_st_timing.sh $CKPT_DIR/dump_mcf_r_noavx.ckpt 10000000 atomic
$R/launch_scripts/run_10M_suite.sh
```

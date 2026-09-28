# Real Machine Checkpointing (RMC) para gem5

Captura el estado completo de un proceso real de x86-64 Linux (memoria,
registros, TLS y descriptores de fichero) y lo reinyecta dentro de **gem5 en
modo Syscall Emulation**, de modo que el simulador arranca directamente en la
Region de Interes sin tener que hacer *fast-forward* de miles de millones de
instrucciones.

## Como funciona

```
  MAQUINA REAL                                   gem5 SE
  ────────────                                   ───────
  benchmark                                      loader (estatico, .text en 0x20000000)
     │ LD_PRELOAD=libckpt.so                        │ mmap MAP_FIXED de cada region
     │ (SIGUSR1 | CKPT_AFTER_NS | CKPT_AT_SYMBOL)   │ reabre y reposiciona los FDs
     ▼                                              │ arch_prctl(ARCH_SET_FS)
  dumper: /proc/self/maps + ucontext ──► .ckpt ──►  │ m5_exit  ← frontera del ROI
                                                    │ restaura GPRs y salta a RIP
                                                    ▼
                                                 el benchmark continua
```

Formato del `.ckpt` (ver `src/checkpoint.h`):

```
[ckpt_header_t][N x ckpt_region_t][M x ckpt_fd_t][payloads en bruto]
```

Los offsets de los payloads se calculan con `CKPT_DATA_OFFSET(N, M)`, que
**tiene que incluir el bloque de descriptores de FD**. Omitirlo desplaza toda
la memoria restaurada y la aplicacion ejecuta basura.

## Estructura

| Ruta | Que es |
|---|---|
| `src/libckpt.c` | Libreria LD_PRELOAD: dispara y captura el checkpoint |
| `src/dumper.c`, `src/dumper_asm.S` | Serializa registros, VMAs y FDs al `.ckpt` |
| `src/loader.c` | Restaurador estatico que corre dentro de gem5 (`build/loader` para objetivos no PIE, `build/loader_pie` para PIE) |
| `src/checkpoint.h` | Formato del fichero, compartido por ambos lados |
| `gem5_configs/x86_mixed.py` | Carga en CPU simple + ROI en DerivO3CPU con caches (ST y SMT-N) |
| `gem5_configs/x86_st_timing.py` | Todo en una CPU simple: bucle rapido de depuracion |
| `gem5_configs/rmc_common.py` | Eleccion automatica de loader segun el checkpoint |
| `launch_scripts/` | Lanzadores: generacion unica (`gen_ckpt.sh`, `benchmarks.sh`), simulacion, prueba e2e en altek (`e2e_altek.sh`), analisis de stats |
| `tools/ckpt_inspect.py` | Diseccion de un `.ckpt`: cabecera, registros, regiones, FDs, bytes en RIP, loader recomendado |
| `test/` | Pruebas nativas del flujo (`run_native_tests.sh`) |
| `docs/` | Bugs corregidos (`BUG_FIXES.md`) y como verificarlos en gem5 (`VERIFICACION_GEM5.md`) |
| `docker/Dockerfile.noavx_glibc` | glibc compilada con `--disable-multi-arch` (sin AVX) |
| `specs/config/gem5_noavx.cfg` | Config de SPEC CPU2017 que compila sin AVX |

## Uso

### 1. Compilar

```bash
make                     # build/loader, build/loader_pie, build/libckpt.so, build/libckpt_static.o
test/run_native_tests.sh # pruebas del flujo en la maquina real, sin gem5
```

### 2. Generar un checkpoint

Siempre con `launch_scripts/gen_ckpt.sh`, el unico camino de generacion (lo
usan todos los scripts), para que todos los checkpoints salgan en las mismas
condiciones:

```bash
launch_scripts/gen_ckpt.sh -t 10000000 -o dump.ckpt -- ./mi_benchmark args...
launch_scripts/gen_ckpt.sh -s mi_funcion_roi:3 -o dump.ckpt -C run_dir -- ./app   # 3a llamada
launch_scripts/gen_ckpt.sh -w -o dump.ckpt -- ./app_estatica dump.ckpt           # ckpt_dump() propio
```

Que fija: ASLR desactivado (`setarch -R` envolviendo a `env`), `GLIBC_TUNABLES`
sin AVX/SSE4, `LD_BIND_NOW=1`, `libckpt.so` por `LD_PRELOAD`, stdin
`/dev/null` (o `-i FICHERO`), comprobacion de AVX/BMI2 en el binario, espera
al volcado completo (se escribe en `.tmp` y se renombra al final) y validacion.
Deja junto al checkpoint `.log`, `.stdout`, `.inspect` y `.meta` (condiciones
de generacion). `gen_ckpt.sh --help` para todas las opciones.

Por debajo usa las variables de `libckpt.so`:

| Variable | Efecto |
|---|---|
| `CKPT_OUTPUT` | Ruta del `.ckpt` (por defecto `dump_<programa>.ckpt`) |
| `CKPT_AFTER_NS` | Vuelca tras N nanosegundos de ejecucion (`-t`) |
| `CKPT_AT_SYMBOL` | Vuelca al llamar a una funcion (breakpoint INT3, con parser ELF propio para binarios PIE) (`-s`) |
| `CKPT_AT_SYMBOL_CALL` | Espera a la N-esima invocacion (por defecto 1) (`-s SIM:N`) |

Sin ninguna de ellas, espera un `SIGUSR1`.

Desde codigo (binarios estaticos, `build/libckpt_static.o`): `ckpt_dump(path)`
devuelve 0 en la ejecucion original, -1 si falla y 1 cuando la ejecucion se
reanuda desde el checkpoint restaurado.

SPEC: los benchmarks se definen una vez en `launch_scripts/benchmarks.sh` y se
generan con `launch_scripts/regenerate_ckpt_noavx.sh [mcf|perlbench|all]`.

### 3. Probar la restauracion en la maquina real

```bash
python3 tools/ckpt_inspect.py dump.ckpt | head      # version, heap, loader recomendado
setarch -R build/loader_pie dump.ckpt --native      # (build/loader si no es PIE)
```

`--native` omite el `m5_exit` (en hardware real es una instruccion ilegal).
Otras opciones del loader: `OLD=NEW` remapea las rutas de los ficheros
abiertos (`/spec2017/=$HOME/spec_cpu_2017/`), `--barrier=FICHERO:N` sincroniza
N loaders en SMT (lo pone `x86_mixed.py`).

### 4. Simular

```bash
# Depuracion rapida: todo en TimingSimpleCPU
launch_scripts/run_st_timing.sh dump.ckpt 1000000 timing

# Medida: carga en TimingSimpleCPU, ROI en DerivO3CPU con caches
launch_scripts/run_mixed.sh mi_tag 10000000 timing --pmu dump.ckpt

# SMT-2 multiprogramado sobre un mismo nucleo
launch_scripts/run_mixed.sh smt2 10000000 timing --pmu a.ckpt b.ckpt

# Tabla de IPC y MPKI
launch_scripts/parse_roi_stats.py ~/TFM/m5out/mi_tag
```

Las configs eligen solas `build/loader` o `build/loader_pie` segun donde este
el `[heap]` del checkpoint: el loader mueve el *program break* del proceso al
final del heap restaurado, y en gem5 el coste es lineal en la distancia (ver
`docs/BUG_FIXES.md`, bug 4). Remapeos de rutas: `LOADER_OPTS="OLD=NEW"` en
`run_st_timing.sh`, `--loader-opts` en `x86_mixed.py`.

`x86_mixed.py` ejecuta el loader en una CPU simple (es puro `memcpy`, no aporta
nada microarquitectonico y en O3 cuesta horas), y en el `m5_exit` que el loader
emite justo antes de saltar al ROI hace `m5.switchCpus()` a `DerivO3CPU`, que
hereda la jerarquia L1/L2 por `takeOverFrom()`. Las stats se resetean ahi, asi
que miden solo el ROI.

### 5. Prueba de extremo a extremo en altek (desde el PC)

```bash
launch_scripts/e2e_altek.sh                        # pruebas de test/
launch_scripts/e2e_altek.sh --spec mcf,perlbench   # + SPEC
```

Compila, genera los checkpoints, los sube a altek con el repo compilado, lanza
un trabajo SLURM que los restaura en gem5 y comprueba su salida, espera y
devuelve el veredicto (0 exito, 1 fallo, 2 error de preparacion). Detalle de
cada prueba en `docs/VERIFICACION_GEM5.md`; guia para lanzarlo y diagnosticar
fallos en `HANDOFF.md`.

### 6. Instalar en el cluster

```bash
launch_scripts/install_on_altek.sh          # clona/actualiza y compila en altek
```

## Requisitos para que gem5 SE pueda ejecutar el checkpoint

gem5 SE no implementa AVX, AVX2 ni BMI2. Hay que eliminarlas por dos vias:

1. **El binario del benchmark.** Compilar con `-mno-avx -mno-avx2 -mno-avx512f`
   (eso hace `specs/config/gem5_noavx.cfg`). Comprobacion:
   ```bash
   objdump -d $BIN | grep -cE '%ymm|bextr|shlx|sarx|shrx|vmovdq'   # tiene que dar 0
   ```
2. **La glibc.** Su resolvedor IFUNC elige rutas AVX2 para `memcpy`, `strlen`,
   `memchr`... al arrancar el proceso. Dos opciones:
   - Generar el checkpoint dentro de `docker/Dockerfile.noavx_glibc`
     (glibc con `--disable-multi-arch`), o
   - exportar `GLIBC_TUNABLES=glibc.cpu.hwcaps=-AVX,-AVX2,-AVX512F,-SSE4_1,-SSE4_2,-SSSE3,...`
     al generar, que fuerza las rutas SSE2.

Si falta cualquiera de las dos, gem5 aborta con
`panic: Unrecognized/invalid instruction executed`.

## Notas

- **Compilacion de benchmarks:** se compilan siempre en local con el contenedor
  Docker y luego se suben al cluster, nunca se compilan en el cluster.
- **Instrumentacion PMU** (`--pmu`): los contadores del gem5 del GAP escriben
  `CPU_*_THD_*_{DISPATCH_STALLS,ISSUE_STALLS,FU_DISTRIBUTION}.csv` con una fila
  por ciclo, en el directorio de trabajo de gem5. Son ~90 MB por millon de
  ciclos: activalos solo cuando vayas a usarlos y vigila el espacio en disco.
- **SPEC CPU2017 no esta en el repo** (software con licencia). Se instala aparte;
  solo se versiona `specs/config/gem5_noavx.cfg`.

Ver `ARCHITECTURE_AND_STUDY_GUIDE.md` para el detalle de los mecanismos de bajo
nivel (PIE/ASLR, INT3, `fs_base`/TLS, pivote de pila) y
`TFM_CONCEPTS_MASTER_LIST.md` para el indice de conceptos.

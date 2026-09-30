# Real Machine Checkpointing (RMC) para gem5

Captura el estado completo de un proceso real de x86-64 Linux (memoria,
registros, TLS y descriptores de fichero) y lo reinyecta dentro de **gem5 en
modo Syscall Emulation**. El simulador arranca directamente en la Región de
Interés (ROI), sin hacer *fast-forward* de miles de millones de instrucciones.

Hay dos formas de restaurar el mismo `.ckpt`:

| | Restauración directa (por defecto) | Loader |
|---|---|---|
| Quién reconstruye el proceso | gem5, en `Process::initState()` | `build/loader`, simulado dentro de gem5 |
| Instrucciones simuladas antes del ROI | 0 | millones (`xz`: 246 M) |
| gem5 necesario | el de [`gap_gem5`](https://github.com/jefemaestro302/gap_gem5) (`Process.rmcCheckpoint`) | cualquiera |
| Se elige con | `--restore direct` | `--restore loader` |

Con `--restore auto` (el valor por defecto de todas las configs) se usa la
directa si el gem5 la soporta. Diseño y validación completos en
[`docs/RESTAURACION_DIRECTA.md`](docs/RESTAURACION_DIRECTA.md).

## Cómo funciona

```
  MÁQUINA REAL                                   gem5 SE
  ────────────                                   ───────
  benchmark
     │ LD_PRELOAD=libckpt.so
     │ (SIGUSR1 | CKPT_AFTER_NS | CKPT_AT_SYMBOL)
     ▼
  dumper: /proc/self/maps + ucontext ──► .ckpt ─┬─► directa: gem5 instala regiones, FDs y
                                                │   registros en initState(); el primer
                                                │   ciclo simulado ya es el ROI
                                                │
                                                └─► loader (estático, .text en 0x20000000):
                                                    mmap MAP_FIXED de cada región, reabre
                                                    los FDs, arch_prctl(ARCH_SET_FS),
                                                    m5_exit (frontera del ROI), restaura
                                                    los GPRs y salta a RIP
```

Formato del `.ckpt` (versión 2, ver `src/checkpoint.h`):

```
[ckpt_header_t][N x ckpt_region_t][M x ckpt_fd_t][payloads en bruto]
```

Los offsets de los payloads se calculan con `CKPT_DATA_OFFSET(N, M)`, que
**tiene que incluir el bloque de descriptores de FD**. Omitirlo desplaza toda
la memoria restaurada y la aplicación ejecuta basura.

## Estructura

| Ruta | Qué es |
|---|---|
| `src/libckpt.c` | Librería LD_PRELOAD: dispara y captura el checkpoint |
| `src/dumper.c`, `src/dumper_asm.S` | Serializa registros, VMAs y FDs al `.ckpt` |
| `src/loader.c` | Restaurador estático que corre dentro de gem5 (`build/loader` para objetivos no PIE, `build/loader_pie` para PIE) y en la máquina real con `--native` |
| `src/checkpoint.h` | Formato del fichero, compartido por todos los lados |
| `gem5_configs/x86_mixed.py` | ROI en DerivO3CPU con cachés (ST y SMT-N), en ambos modos de restauración |
| `gem5_configs/x86_mixed_2core.py` | Dos núcleos O3 con SMT cada uno (`--ckpts0` y `--ckpts1`) |
| `gem5_configs/x86_st_timing.py` | Todo en una CPU simple: bucle rápido de depuración |
| `gem5_configs/rmc_common.py` | Modo de restauración y elección automática de loader |
| `launch_scripts/` | Lanzadores: generación (`gen_ckpt.sh`, `benchmarks.sh`), simulación, prueba e2e en altek (`e2e_altek.sh`), análisis de stats |
| `tools/ckpt_inspect.py` | Disección de un `.ckpt`: cabecera, regiones, FDs, bytes en RIP, loader recomendado |
| `test/` | Pruebas nativas del flujo (`run_native_tests.sh`) y programas de prueba para gem5 |
| `test/test_page_colour.c` | Microbenchmark del sesgo de coloreado de páginas del loader (ver más abajo) |
| `docs/` | `RESTAURACION_DIRECTA.md`, `BUG_FIXES.md` y `VERIFICACION_GEM5.md` |
| `docker/Dockerfile.spec` | Imagen `gem5_noavx_env`: compiladores para SPEC sin AVX |
| `specs/config/gem5_noavx.cfg` | Config de SPEC CPU2017 que compila sin AVX |
| `HANDOFF.md` | Registro de la validación en altek y de la unificación de versiones (cerrado el 29-09-2026) |

## Uso

### 1. Compilar

```bash
make                     # build/loader, build/loader_pie, build/libckpt.so, build/libckpt_static.o
test/run_native_tests.sh # pruebas del flujo en la máquina real, sin gem5
```

### 2. Generar un checkpoint

Siempre con `launch_scripts/gen_ckpt.sh`, el único camino de generación (lo
usan todos los scripts), para que todos los checkpoints salgan en las mismas
condiciones:

```bash
launch_scripts/gen_ckpt.sh -t 10000000 -o dump.ckpt -- ./mi_benchmark args...
launch_scripts/gen_ckpt.sh -s mi_funcion_roi:3 -o dump.ckpt -C run_dir -- ./app   # 3ª llamada
launch_scripts/gen_ckpt.sh -w -o dump.ckpt -- ./app_estatica dump.ckpt           # ckpt_dump() propio
```

Fija ASLR desactivado (`setarch -R` envolviendo a `env`), `GLIBC_TUNABLES` sin
AVX/SSE4, `LD_BIND_NOW=1`, `libckpt.so` por `LD_PRELOAD`, stdin `/dev/null`
(o `-i FICHERO`) y comprueba AVX/BMI2 en el binario. Espera al volcado
completo (se escribe en `.tmp` y se renombra al final) y lo valida. Deja junto
al checkpoint `.log`, `.stdout`, `.inspect` y `.meta` (condiciones de
generación). `gen_ckpt.sh --help` lista todas las opciones.

Por debajo usa las variables de `libckpt.so`:

| Variable | Efecto |
|---|---|
| `CKPT_OUTPUT` | Ruta del `.ckpt` (por defecto `dump_<programa>.ckpt`) |
| `CKPT_AFTER_NS` | Vuelca tras N nanosegundos de ejecución (`-t`) |
| `CKPT_AT_SYMBOL` | Vuelca al llamar a una función (breakpoint INT3, con parser ELF propio para binarios PIE) (`-s`) |
| `CKPT_AT_SYMBOL_CALL` | Espera a la N-ésima invocación (por defecto 1) (`-s SIM:N`) |

Sin ninguna de ellas, espera un `SIGUSR1`.

Desde código (binarios estáticos, `build/libckpt_static.o`): `ckpt_dump(path)`
devuelve 0 en la ejecución original, -1 si falla y 1 cuando la ejecución se
reanuda desde el checkpoint restaurado.

SPEC solo se compila en Docker (`generate_all_spec_checkpoints.sh
--build-only [all|bench...]`). Cualquier benchmark rate preparado sirve sin
tocar nada: `launch_scripts/benchmarks.sh` lee su comando del `speccmds.cmd` de
runcpu. Se generan en el PC y se suben a altek en un paso:

```bash
launch_scripts/regenerate_ckpt_noavx.sh --upload mcf lbm   # o "all"
```

Deja en altek `~/checkpoints/dump_<b>.ckpt`, el directorio de ejecución del
benchmark en `~/spec_cpu_2017/...` y un `dump_<b>.ckpt.remap` con la
traducción de rutas PC -> altek, que `run_mixed.sh` y `run_st_timing.sh`
aplican solos.

### 3. Probar la restauración en la máquina real

```bash
python3 tools/ckpt_inspect.py dump.ckpt | head      # versión, heap, loader recomendado
setarch -R build/loader_pie dump.ckpt --native      # (build/loader si no es PIE)
```

`--native` omite el `m5_exit` (en hardware real es una instrucción ilegal).
Otras opciones del loader: `OLD=NEW` remapea las rutas de los ficheros
abiertos (`/spec2017/=$HOME/spec_cpu_2017/`), `--barrier=FICHERO:N`
sincroniza N loaders en SMT (lo pone `x86_mixed.py`).

### 4. Simular

```bash
# Depuración rápida: todo en una CPU simple
launch_scripts/run_st_timing.sh dump.ckpt 1000000 timing

# Medida: ROI en DerivO3CPU con cachés
launch_scripts/run_mixed.sh mi_tag 10000000 timing --pmu dump.ckpt

# SMT-2 multiprogramado sobre un mismo núcleo
launch_scripts/run_mixed.sh smt2 10000000 timing --pmu a.ckpt b.ckpt

# Forzar un modo. En directa, calentar cachés N instrucciones antes del ROI
RMC_RESTORE=loader launch_scripts/run_mixed.sh mi_tag 10000000 timing dump.ckpt
RMC_RESTORE=direct RMC_WARMUP=5000000 launch_scripts/run_mixed.sh mi_tag 10000000 atomic dump.ckpt

# Dos núcleos con SMT-2 cada uno (directamente con gem5)
gem5.opt x86_mixed_2core.py --loader build/loader --ckpts0 a.ckpt b.ckpt --ckpts1 c.ckpt d.ckpt

# Tabla de IPC y MPKI
launch_scripts/parse_roi_stats.py ~/TFM/m5out/mi_tag
```

En directa la O3 arranca en el tick 0 con el proceso ya restaurado, y las
stats miden solo el ROI. Con loader, `x86_mixed.py` ejecuta el loader en una
CPU simple (es puro `memcpy`, no aporta nada microarquitectónico y en O3 cuesta
horas) y en el `m5_exit` que el loader emite justo antes de saltar al ROI hace
`m5.switchCpus()` a `DerivO3CPU`, que hereda la jerarquía L1/L2 por
`takeOverFrom()`. Las stats se resetean ahí.

Con loader, las configs eligen solas `build/loader` o `build/loader_pie` según
dónde esté el `[heap]` del checkpoint: el loader mueve el *program break* al
final del heap restaurado, y en gem5 el coste es lineal en la distancia (ver
`docs/BUG_FIXES.md`, bug 4). Remapeos de rutas: el `<ckpt>.remap` de cada
checkpoint, más `LOADER_OPTS="OLD=NEW ..."` si hace falta (en las configs,
`--loader-opts`).

### 5. Prueba de extremo a extremo en altek (desde el PC)

```bash
launch_scripts/e2e_altek.sh                                  # pruebas de test/
launch_scripts/e2e_altek.sh --spec mcf,perlbench             # + SPEC
launch_scripts/e2e_altek.sh --restore direct --spec all      # los 23 SPEC rate, restauración directa
launch_scripts/e2e_altek.sh --restore loader --spec all      # ídem con loader
```

Compila, genera los checkpoints, los sube a altek con el repo compilado, lanza
un trabajo SLURM que los restaura en gem5 y comprueba su salida, espera y
devuelve el veredicto (0 éxito, 1 fallo, 2 error de preparación). Si se corta
la terminal, `--attach ID` se reengancha. Detalle de cada prueba en
`docs/VERIFICACION_GEM5.md`.

Estado a 29-09-2026: **30/30** (7 pruebas de `test/` + 23 SPEC) en los dos
modos. La suma de tiempos de gem5 baja de 5214 s con loader a 1110 s en
directa.

### 6. Instalar en el cluster

```bash
launch_scripts/install_on_altek.sh master   # clona/actualiza el repo en altek y compila loaders y libckpt.so
```

El gem5 de altek (`~/gap_gem5`) es un clon git de `main` de `gap_gem5`. Se
actualiza con `git pull --ff-only` y se recompila **en el nodo de login** (el
gcc 11 de los nodos de cómputo es otra versión y el binario resultante
corrompe el estado restaurado) con `gem5/compile_altek.sh`, que es un script
del repo `gap_gem5`.

## Diferencia conocida con el loader: coloreado de páginas

Con el loader, la aplicación queda en marcos físicos alternos (el `memcpy`
alterna páginas del `.ckpt` y de destino), así que con una L2 de 256 KiB y 8
vías solo usa la mitad de los conjuntos. En `mcf` eso da un IPC un 15 % menor
que en directa (0,616 frente a 0,724) sin diferencias en L1D ni en la TLB.
La restauración directa reparte los marcos por todos los colores, como Linux.

- Resultados nuevos: restauración directa (con `--warmup` si el ROI es corto).
- Comparar con resultados antiguos hechos con el loader: `--restore loader`,
  que reproduce el mismo sesgo.
- Explicación, tabla del microbenchmark (`test/test_page_colour.c`) y la de
  `mcf` en [`docs/RESTAURACION_DIRECTA.md`](docs/RESTAURACION_DIRECTA.md).

## Requisitos para que gem5 SE pueda ejecutar el checkpoint

gem5 SE no implementa AVX, AVX2 ni BMI2. Hay que eliminarlas por dos vías:

1. **El binario del benchmark.** Compilar con `-mno-avx -mno-avx2 -mno-avx512f`
   (lo hace `specs/config/gem5_noavx.cfg`). Comprobación:
   ```bash
   objdump -d $BIN | grep -cE '%ymm|bextr|shlx|sarx|shrx|vmovdq'   # tiene que dar 0
   ```
2. **La glibc.** Su resolvedor IFUNC elige rutas AVX2 para `memcpy`, `strlen`,
   `memchr`... al arrancar el proceso. `gen_ckpt.sh` exporta
   `GLIBC_TUNABLES=glibc.cpu.hwcaps=-AVX,-AVX2,-AVX512F,-SSE4_1,-SSE4_2,-SSSE3,...`
   al generar, que fuerza las rutas SSE2.

Si falta cualquiera de las dos, gem5 aborta con
`panic: Unrecognized/invalid instruction executed`.

## Notas

- **Docker solo compila SPEC** (`generate_all_spec_checkpoints.sh`, imagen de
  `docker/Dockerfile.spec`), siempre en local; nunca se compila en el cluster.
  Generar checkpoints, el e2e y la simulación no usan Docker.
- **Instrumentación PMU** (`--pmu`): los contadores del gem5 del GAP escriben
  `CPU_*_THD_*_{DISPATCH_STALLS,ISSUE_STALLS,FU_DISTRIBUTION}.csv` con una fila
  por ciclo, en el directorio de trabajo de gem5. Son ~90 MB por millón de
  ciclos: actívalos solo cuando vayas a usarlos y vigila el espacio en disco.
- **SPEC CPU2017 no está en el repo** (software con licencia). Se instala
  aparte; solo se versiona `specs/config/gem5_noavx.cfg`.
- **Errores típicos de la restauración directa** (`Process.rmcCheckpoint` no
  existe, `bad magic`, falta un remapeo de rutas...): tabla de diagnóstico en
  `HANDOFF.md`, sección 5.

Ver `ARCHITECTURE_AND_STUDY_GUIDE.md` para el detalle de los mecanismos de bajo
nivel (PIE/ASLR, INT3, `fs_base`/TLS, pivote de pila) y
`TFM_CONCEPTS_MASTER_LIST.md` para el índice de conceptos.

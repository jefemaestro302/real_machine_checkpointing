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
| `src/loader.c` | Restaurador estatico que corre dentro de gem5 |
| `src/checkpoint.h` | Formato del fichero, compartido por ambos lados |
| `gem5_configs/x86_mixed.py` | Carga en CPU simple + ROI en DerivO3CPU con caches (ST y SMT-N) |
| `gem5_configs/x86_st_timing.py` | Todo en una CPU simple: bucle rapido de depuracion |
| `launch_scripts/` | Lanzadores (generacion, simulacion, analisis de stats) |
| `tools/ckpt_inspect.py` | Diseccion de un `.ckpt`: cabecera, registros, regiones, FDs, bytes en RIP |
| `docker/Dockerfile.noavx_glibc` | glibc compilada con `--disable-multi-arch` (sin AVX) |
| `specs/config/gem5_noavx.cfg` | Config de SPEC CPU2017 que compila sin AVX |

## Uso

### 1. Compilar

```bash
make                     # build/loader, build/libckpt.so, build/libckpt_static.o
```

### 2. Generar un checkpoint

```bash
LD_PRELOAD=./build/libckpt.so CKPT_AFTER_NS=10000000 \
CKPT_OUTPUT=dump.ckpt ./mi_benchmark args...
```

| Variable | Efecto |
|---|---|
| `CKPT_OUTPUT` | Ruta del `.ckpt` (por defecto `libckpt_dump.ckpt`) |
| `CKPT_AFTER_NS` | Vuelca tras N nanosegundos de ejecucion |
| `CKPT_AT_SYMBOL` | Vuelca al llamar a una funcion (breakpoint INT3, con parser ELF propio para binarios PIE) |
| `CKPT_AT_SYMBOL_CALL` | Espera a la N-esima invocacion (por defecto 1) |

Sin ninguna de ellas, espera un `SIGUSR1`.

Para SPEC en el cluster: `launch_scripts/regenerate_ckpt_noavx.sh [mcf|perlbench|all]`.

### 3. Simular

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

`x86_mixed.py` ejecuta el loader en una CPU simple (es puro `memcpy`, no aporta
nada microarquitectonico y en O3 cuesta horas), y en el `m5_exit` que el loader
emite justo antes de saltar al ROI hace `m5.switchCpus()` a `DerivO3CPU`, que
hereda la jerarquia L1/L2 por `takeOverFrom()`. Las stats se resetean ahi, asi
que miden solo el ROI.

### 4. Instalar en el cluster

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

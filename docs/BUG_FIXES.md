# Bugs corregidos en la rama `bug-fixes`

Lista de los fallos encontrados en `master` (analisis estatico + pruebas en
maquina real), con su causa, su arreglo y como se ha comprobado. La forma de
verificarlos **en gem5** esta en [`VERIFICACION_GEM5.md`](VERIFICACION_GEM5.md).

Pruebas nativas (sin gem5) de todos los que se pueden reproducir en el host,
y prueba de extremo a extremo en gem5/altek lanzada desde el PC:

```bash
test/run_native_tests.sh 10          # 10 repeticiones de las pruebas aleatorias
launch_scripts/e2e_altek.sh          # genera, sube, simula en altek y da el veredicto
```

Leyenda de la columna "Evidencia":
**N** = reproducido en maquina real con `master` y resuelto con `bug-fixes`;
**C** = confirmado leyendo el codigo de gem5 (`stable`), verificar en gem5;
**E** = estatico / script.

## Criticos: corrompen la restauracion o la simulacion

| # | Bug | Evidencia |
|---|---|---|
| 1 | El loader escribia en la *red zone* de la pila restaurada | N: 5/5 corruptos -> 5/5 OK |
| 2 | Volcado dentro del manejador de senal con `fopen`/`fprintf` (malloc) | N: 38/40 bloqueos -> 0/40 |
| 3 | El `.ckpt` se mapeaba encima de las librerias del objetivo | N: SIGSEGV siempre (sin ASLR) |
| 4 | Program break del loader en vez del del objetivo: `malloc` corrupto | N: `double free or corruption (out)` -> OK; C |
| 5 | `ckpt_dump()` (asm) generaba un `ckpt_regs_t` invalido | N/E |
| 6 | Checkpoints truncados dados por buenos (`kill -9` a los 4 s, errores ignorados) | N/E |

### 1. Red zone de la pila restaurada (`src/loader.c`)
- **Causa**: el salto final hacia `movq rsp; pushq rip; pushq rflags; popfq; ret`
  **sobre la pila del objetivo**, pisando `[rsp-16, rsp)`. Con disparo por senal
  (`CKPT_AFTER_NS`, `SIGUSR1`) la ejecucion puede estar en una funcion hoja que
  guarda variables en la red zone (128 B bajo `%rsp`): el kernel la respeta al
  entregar la senal, asi que el volcado es correcto, pero el loader la machacaba.
- **Sintoma**: corrupcion silenciosa e intermitente del ROI (o crash).
- **Arreglo**: el trampolin final restaura RFLAGS en la pila *scratch* y salta a
  RIP con `jmp *mem`; nunca escribe en la pila restaurada.
- **Prueba**: `test/test_redzone.c`.

### 2. Volcado no async-signal-safe (`src/dumper.c`, `src/libckpt.c`)
- **Causa**: `ckpt_dump_impl()` corre dentro del manejador de `SIGUSR1`/`SIGTRAP`
  y usaba `fopen("/proc/self/maps")`, `fgets` y `fprintf`, que llaman a `malloc`
  o toman locks de stdio. Si la senal llega con el programa dentro de `malloc`
  (perlbench, cualquier app que asigne memoria), bloqueo o heap corrupto.
- **Arreglo**: `/proc/self/maps` se lee con `open`/`read` a un buffer estatico, y
  todo el log del camino de volcado va por `ckpt_log()` (buffer estatico +
  `write(2)`).
- **Prueba**: `test/test_signal_malloc.c` (con `master` se colgaban 38 de 40
  ejecuciones).

### 3. `.ckpt` mapeado encima de las librerias del objetivo (`src/loader.c`)
- **Causa**: `mmap(NULL, tam_ckpt)` cae justo bajo el tope de la zona mmap (en
  gem5, `mmap_end = 0x7ffff7fff000`), que es donde un proceso sin ASLR tiene
  ld.so, libc y libckpt.so. El bucle de restauracion desmapeaba entonces sus
  propios datos de origen.
- **Arreglo**: el `.ckpt` se mapea en una direccion que no usa ninguna region
  (>= 16 TiB y 1 TiB por encima del heap), el loader **valida** antes de tocar
  nada que ninguna region solape su imagen, su heap, la pagina scratch o el
  `.ckpt` (y aborta con un mensaje claro), y el `.ckpt` se desmapea antes de
  entrar al ROI.

### 4. Program break (`src/loader.c`, `Makefile`)
- **Causa**: tras restaurar, el kernel (o gem5) conserva el *break* del loader,
  pero la libc restaurada sigue usando `brk()` sobre el heap del objetivo:
  - heap por **encima** del break (PIE, p.ej. SPEC): `brk()` falla, glibc guarda
    el break del loader en `__curbrk` y el siguiente recorte del heap calcula
    `released = heap_top - brk_loader` y destroza el *top chunk*
    (`double free or corruption (out)`); pasa igual en gem5;
  - heap por **debajo** (no PIE, p.ej. `target_app`): gem5 trata
    `brk(heap_end+n)` como una *reduccion*: desmapea, devuelve exito sin mapear
    nada y el ROI falla en la primera pagina nueva del heap.
- **Arreglo**: el loader mueve el break al final del `[heap]` restaurado:
  lo **amplia** antes de restaurar (heap por encima) o lo **reduce** desde el
  trampolin (heap por debajo; se ejecuta desde la pagina scratch porque la
  reduccion desmapea el propio loader). Como gem5 comprueba el rango pagina a
  pagina, la distancia importa: hay dos binarios,
  `build/loader` (break en ~0x200xxxxx, para no PIE) y `build/loader_pie`
  (break anclado en `0x555500000000`, para PIE), y las configs de gem5 eligen
  solas segun el checkpoint (`gem5_configs/rmc_common.py`).
  En `--native` Linux no deja bajar el break por debajo de `start_brk`: se usa
  `prctl(PR_SET_MM)` (requiere `CAP_SYS_RESOURCE`, como CRIU) y si no se puede
  se avisa.

### 5. `ckpt_dump()` en ensamblador (`src/dumper_asm.S`)
- **Causa**: reservaba 256 B para un `ckpt_regs_t` de 4352 B: `fpregs_size`
  quedaba con basura de la pila (el loader podia hacer `fxrstor` de basura ->
  `#GP`) y `memcpy` leia 4 KB fuera del buffer. Ademas `rax` restaurado era
  basura (valor de retorno aleatorio al restaurar) y faltaba
  `.note.GNU-stack` (pila ejecutable en `libckpt.so`).
- **Arreglo**: marco de 4352 B alineado a 64, `fxsave` del estado FPU/SSE,
  `rax = 1` (`ckpt_dump()` devuelve 1 al restaurar, 0/-1 en la ejecucion
  original) y nota de pila no ejecutable.

### 6. Checkpoints truncados (`src/dumper.c`, `launch_scripts/regenerate_ckpt_noavx.sh`, `src/loader.c`)
- **Causa**: el script esperaba a que el fichero *existiera* (ocurre en el
  `open`) y mataba el proceso 4 s despues; con un volcado lento los
  descriptores (que se escriben al final) quedaban con offsets a 0. Ademas un
  error de `write` a mitad de region solo avisaba y el volcado devolvia exito.
- **Arreglo**: el volcado se escribe en `<out>.tmp` y se renombra al terminar
  (el nombre final solo existe si esta completo); cualquier error aborta; el
  script espera al fichero final y comprueba `Dump complete`; el loader y
  `tools/ckpt_inspect.py` rechazan payloads fuera del fichero.

## Altos

| # | Bug | Arreglo |
|---|---|---|
| 7 | `m5_exit` ejecutado siempre: SIGILL en maquina real (las pruebas locales no podian funcionar) | opcion `--native` del loader |
| 8 | Fallos de `mmap` en la restauracion ignorados | `DIE` |
| 9 | FDs: stdin redirigido desde fichero no se restauraba; `O_RDWR` a `/dev/null`; remapeo por prefijo sin respetar componentes (`/a/b=/x` reescribia `/a/bc`); `dup2`/`lseek` sin comprobar | ver abajo |
| 10 | SMT-N: el primer loader ejecutaba su ROI en la CPU simple mientras los demas restauraban | barrera `--barrier=FICHERO:N` |
| 11 | vDSO copiado del host: reloj congelado o sin sentido tras restaurar en gem5 | entradas del vDSO -> syscalls |
| 12 | `Makefile`: un `CFLAGS`/`LDFLAGS` del entorno eliminaba `-mno-avx`/`-static` | `override` |

- **9**: stdin se restaura si es un fichero regular en lectura (p.ej.
  `503.bwaves_r < entrada`); stdout/stderr siguen siendo los de gem5; `O_RDWR`
  reabre el fichero real (con aviso: remapear a una copia); pipes/sockets se
  avisan y se omiten.
- **10**: tras restaurar, cada loader anade un byte a un fichero comun y espera
  a que haya N antes de su `m5_exit`. `x86_mixed.py` lo configura solo e imprime
  las instrucciones de cada hilo en cada `m5_exit`.
- **11**: glibc llama a `clock_gettime`/`gettimeofday`/`time`/`getcpu` a traves
  del vDSO; el copiado lee una `[vvar]` congelada. El loader sobrescribe cada
  entrada exportada con `mov $NR,%eax; syscall; ret` (gem5 implementa todas).

## Medios / bajos

| # | Bug | Arreglo |
|---|---|---|
| 13 | `MAX_REGIONS=256` truncaba regiones en silencio; rutas de FD > 255 B truncadas | 1024 y error; aviso y fd no restaurable |
| 14 | `CKPT_VERSION` seguia en 1 tras cambiar el formato | version 2 (el loader rechaza las antiguas) |
| 15 | `elf_find_symbol`: desplazamiento de carga mal si `p_vaddr` no esta alineado a pagina | redondeo a pagina |
| 16 | Restos de depuracion en el loader (volcaba `/proc/self/maps` al stdout del objetivo, "MAIN FOUND STACK", funciones muertas) | eliminados |

## Generacion: cada script generaba distinto

Habia al menos cinco caminos de generacion (`regenerate_ckpt_noavx.sh`,
`run_spec_dump.sh` y `generate_all_spec_checkpoints.sh` en Docker con otra
glibc, los scripts de Tailbench, los de prueba), cada uno con su entorno. Ahora
**todo checkpoint se genera con `launch_scripts/gen_ckpt.sh`**, y los
benchmarks SPEC se definen una sola vez en `launch_scripts/benchmarks.sh`.
`gen_ckpt.sh` fija las condiciones y ademas corrige:

| # | Problema | Arreglo |
|---|---|---|
| 17 | El directorio de trabajo no se restauraba: las rutas relativas que el programa abre durante el ROI (p.ej. `perlbench -I./lib`) se resolvian contra el cwd de gem5 | el checkpoint guarda el cwd (pseudo-FD `CKPT_FD_CWD`); las configs lo pasan a `Process(cwd=...)` con los remapeos, y `--native` hace `chdir` |
| 18 | La entrada estandar se heredaba de quien lanzara el script (terminal, cron...) | `/dev/null` por defecto; `-i FICHERO` (y `BENCH_STDIN`) para los que leen de stdin |
| 19 | Enlazado perezoso: la primera llamada a una funcion de biblioteca dentro del ROI ejecutaba el resolvedor de ld.so, que salva registros con `xsave`/`xsavec` segun la CPU | `LD_BIND_NOW=1`: todo se resuelve al arrancar |
| 20 | Cada script comprobaba (o no) el AVX del binario y esperaba el volcado a su manera | comprobacion unica, espera al fichero completo, validacion con `ckpt_inspect.py` y `.meta` con las condiciones de generacion |

Los scripts de Tailbench (`generate_all_checkpoints_noavx.sh`,
`run_noavx_glibc_checkpoint.sh`) generan con una glibc propia y un `ld.so`
explicito dentro de Docker; se mantienen marcados como LEGADO y avisan al
ejecutarse.

## Scripts

| Fichero | Bug | Arreglo |
|---|---|---|
| `launch_scripts/install_on_altek.sh` | `make -C $DEST $DEST/build/loader`: targets con ruta absoluta -> `No rule to make target`, oculto por `\| tail` | targets relativos, `pipefail`, comprueba los binarios |
| `launch_scripts/run_mixed.sh` | `cd $OUTDIR` antes de gem5: checkpoints relativos no se encuentran | `realpath` |
| `launch_scripts/run_10M_suite.sh` | `dump_perlbench_noavx_build.ckpt` no lo genera nadie | `dump_perlbench_noavx.ckpt` y comprobacion |
| `launch_scripts/regenerate_ckpt_noavx.sh` | ver bug 6; sin `setarch -R`; `kill` al subshell y no al benchmark | espera correcta, `setarch -R env ...`, `exec` |
| `test/run_test.sh` | remapeo sin `=`; `rm` de un fichero inexistente con `set -e`; modificaba `test/new_dir/input1.txt` versionado | reescrito en un directorio temporal |
| `run_example.sh`, `run_noavx_glibc_checkpoint.sh` | loader nativo -> SIGILL; compilacion a mano sin `dumper_asm.S` | `--native`, `make` |
| `run_gem5.sh` | `se.py` termina en el `m5_exit` sin simular el ROI; `O3CPU` no es valido | atajo a `launch_scripts/` |
| `test_fd_slurm.sh`, `test_perlbench_slurm.sh` | ruta `real_machine_checkpoint` (sin "-ing"), `x86_st.py` que no esta en el repo | eliminados: los cubre `e2e_altek.sh` (pruebas `fd` y `--spec perlbench`) |
| `sync_benchmark_to_altek.sh` | misma ruta sin "-ing"; subia la plantilla SLURM eliminada | ruta del repo, sube ambos loaders |
| `run_spec_dump.sh`, `generate_all_spec_checkpoints.sh` | generaban en Docker con otra glibc y sin desactivar ASLR | Docker solo compila; generan con `regenerate_ckpt_noavx.sh` / `gen_ckpt.sh` |

## Notas de uso que salen de los arreglos

- **Genera siempre con `launch_scripts/gen_ckpt.sh`.** Desactiva ASLR con
  `setarch -R` *envolviendo* a `env` (al reves, libckpt.so se cargaria en
  `setarch`, quitaria `LD_PRELOAD` del entorno y la app arrancaria sin ella).
  Con ASLR, el heap de un binario estatico no PIE puede caer encima del loader
  (`0x20000000`); el loader lo detecta y aborta. En Docker `setarch -R` no
  funciona: `gen_ckpt.sh` se niega salvo con `RMC_ALLOW_ASLR=1`.
- Apps lanzadas con un `ld.so` explicito (scripts de Tailbench): con ASLR su heap
  cae en la zona PIE (usar `loader_pie`); sin ASLR queda junto a ld.so, lejos de
  ambos loaders, y el loader avisa de que no mueve el break.
- Si la salida estandar del programa va a una tuberia o fichero, lo que hubiera en
  el buffer de stdio al volcar forma parte del checkpoint y se vuelve a imprimir
  al restaurar. No es un fallo.

## Pendiente (decision del autor)

- `ml_gem5_benchmarks` es un submodulo (gitlink) sin `.gitmodules`: un clon no
  puede inicializarlo. Hay que anadir `.gitmodules` con su URL o quitarlo.

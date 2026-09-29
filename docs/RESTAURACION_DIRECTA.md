# Restauracion directa en gem5 (zero-cycle restore)

Hasta ahora un checkpoint RMC se restauraba **simulando** `build/loader`
(o `loader_pie`): un binario estatico que, dentro de gem5, reconstruye el
proceso con `mmap`/`memcpy`/`brk`/`dup2`/`arch_prctl`/`fxrstor` y marca la
frontera del ROI con `m5_exit`. Funciona con cualquier gem5, pero cuesta
millones de instrucciones simuladas por checkpoint, una fase de simulacion
aparte y una pila de trucos (pagina scratch, trampolin, dos loaders segun el
heap, barrera SMT).

Con la restauracion directa, **gem5 instala el checkpoint el mismo** en
`Process::initState()`, antes del primer tick: el primer ciclo simulado ya es
la primera instruccion del ROI. No se simula nada del loader.

| | loader (antes) | directa (ahora) |
|---|---|---|
| Instrucciones simuladas antes del ROI | millones (una por byte copiado, aprox.) | **0** |
| Fase de carga + `m5_exit` + `switchCpus` | si | no (la O3 arranca en el tick 0) |
| Memoria fisica simulada | ~2x el checkpoint (el `.ckpt` mapeado + las regiones) | <= 1x (las paginas a cero no se reservan) |
| Loader segun heap PIE / no PIE (bug 4) | `loader` o `loader_pie` | no aplica: el break se fija al final del `[heap]` |
| Barrera SMT (bug 10), `--seq-load` | necesarias | no aplican: todos los hilos empiezan a la vez |
| Red zone, trampolin, pagina scratch (bugs 1, 3, 21) | necesarios | no existen |
| gem5 necesario | cualquiera | el del GAP con este parche (`Process.rmcCheckpoint`) |

El formato del `.ckpt` **no cambia** (v2): los checkpoints existentes valen
tal cual, y el loader sigue disponible (`--restore loader`).

## Uso

Las tres configs aceptan `--restore auto|direct|loader`. `auto` (por
defecto) usa `direct` si el gem5 tiene `Process.rmcCheckpoint` y `loader` si
no, asi que con un gem5 sin el parche todo sigue como antes.

```bash
# Depuracion: todo en CPU simple
RMC_RESTORE=direct launch_scripts/run_st_timing.sh dump.ckpt 1000000 atomic

# Medida: ROI en O3 desde el tick 0 (con PMU, SMT-N...)
RMC_RESTORE=direct launch_scripts/run_mixed.sh mi_tag 10000000 timing --pmu a.ckpt b.ckpt

# Calentar caches con N instrucciones en la CPU simple antes de pasar a O3
RMC_RESTORE=direct RMC_WARMUP=5000000 launch_scripts/run_mixed.sh mi_tag 10000000 atomic a.ckpt

# e2e con uno u otro modo
launch_scripts/e2e_altek.sh --restore direct
launch_scripts/e2e_altek.sh --restore loader
```

Directamente con gem5:

```bash
gem5.opt x86_mixed.py --loader build/loader --ckpts a.ckpt --restore direct [--warmup N]
gem5.opt x86_st_timing.py --cmd build/loader --options "a.ckpt OLD=NEW" --restore direct
gem5.opt x86_mixed_2core.py --loader build/loader --ckpts0 a b --ckpts1 c d --restore direct
```

O desde cualquier config propia:

```python
Process(executable="build/loader",          # solo elige ISA/SO; no se carga
        cmd=["build/loader", "a.ckpt"],
        cwd=cwd_del_checkpoint,              # rmc_common.process_cwd()
        rmcCheckpoint="a.ckpt",
        rmcRemaps=["/ruta/pc=/ruta/altek"])
```

`--debug-flags=Rmc` muestra cada region y cada FD restaurados.

En `x86_mixed.py` y `x86_mixed_2core.py` la O3 se sigue llamando
`system.o3` / `system.o3_N`, asi que las stats y `parse_roi_stats.py` son
las mismas en ambos modos. Como en el tick 0 no hay nada que descartar,
`m5.stats.reset()` no cambia nada, pero se mantiene.

## Como funciona (gem5, `gap_gem5`)

- `src/sim/Process.py`: parametros `rmcCheckpoint` (ruta del `.ckpt`) y
  `rmcRemaps` (`OLD=NEW`, la misma semantica por componentes que el loader).
- `src/sim/rmc_checkpoint.{hh,cc}`: lectura y validacion del `.ckpt` (espejo
  de `src/checkpoint.h`, con `static_assert` de los tamanos) y la parte
  independiente de la ISA:
  - **Memoria**: cada region pasa a ser una VMA de `MemState` (asi siguen
    funcionando `munmap`, `mremap`, `brk` y la paginacion bajo demanda) y
    sus paginas con datos se reservan y se escriben; las paginas enteramente
    a cero se dejan a la paginacion bajo demanda (`fixupFault` da una pagina
    nueva, a cero). Las regiones sin permiso de lectura solo reservan el
    rango. `[vsyscall]` se omite: gem5 pone la suya.
  - **Mapa de direcciones**: `brk` = final del `[heap]` (o, sin heap, final
    del ejecutable), pila = la region `[stack]` (crece hacia abajo como
    siempre), y los `mmap` nuevos se colocan por debajo de la region mas
    baja entre el heap y la pila, como haria Linux.
  - **vDSO**: las entradas exportadas se reescriben a
    `mov $NR,%eax; syscall; ret` (igual que el loader, bug 11).
  - **FDs**: misma politica que el loader: stdin/stdout/stderr son los de
    gem5 salvo un stdin redirigido desde un fichero; escrituras a
    `/dev/null`; lectura y lectura/escritura se reabren (tras los remapeos y
    las redirecciones de gem5) en su offset; lo que no es un fichero regular
    se avisa y se omite. El cwd lo pone la config (`Process.cwd`); si no
    coincide con el del checkpoint, gem5 avisa.
- `src/arch/x86/process.cc`, `X86_64Process::initState()`: si hay
  `rmcCheckpoint`, no se carga la imagen del ejecutable ni se construye la
  pila inicial (`argsInit`); se restauran memoria y FDs, se prepara el resto
  del estado x86 como siempre (vsyscall, segmentos, CR0/CR4/EFER) y **al
  final** se cargan los registros: GPRs, RFLAGS, `fs_base`/`gs_base` y el
  estado x87/SSE de la imagen FXSAVE (mismo mapeo que usa gem5 con KVM), y
  el PC en `roi_entry_rip`.

Como `initState()` no se llama al restaurar un checkpoint nativo de gem5,
un `m5.checkpoint()` tomado despues de una restauracion directa se restaura
de la forma normal de gem5.

## Diferencias de comportamiento

- El **entorno** del proceso (`Process.env`) no se usa: el entorno es el del
  checkpoint (lo que habia en la pila al volcar), que `gen_ckpt.sh` ya
  genera con `GLIBC_TUNABLES` sin AVX.
- `argv[0]`/`cmd` solo aparecen en los mensajes de gem5.
- Las caches y la TLB empiezan frias en el primer ciclo del ROI. Con el
  loader tambien empezaban practicamente frias (lo que las calentaba era el
  `memcpy` del loader, no la aplicacion); `--warmup N` ejecuta N
  instrucciones de la propia aplicacion en la CPU simple antes de medir.
- `--seq-load` y la barrera del loader no aplican.

## Validacion

En este contenedor (4 nucleos), con el `gem5.opt` del GAP compilado con el
parche y la e2e real (`e2e_altek.sh` con `RMC_REMOTE=local` y un SLURM
simulado), los mismos checkpoints en ambos modos:

| Prueba | loader | directa | Instrucciones de ROI (loader / directa) |
|---|---|---|---|
| `target_app` (checksum = nativo) | PASS, 7 s | PASS, 0 s | 14060 / 14039 |
| `static_malloc` (brk crece y se recorta) | PASS | PASS | 562500 / 562479 |
| `fd` (remapeo de ruta) | PASS | PASS | 3799 / 3778 |
| `redzone` | PASS | PASS | 150 M / 150 M |
| `signal_malloc` | PASS | PASS | 150 M / 150 M |
| `vdso` | PASS | PASS | 150 M / 150 M |
| `smt2` (SMT-2, O3) | PASS | PASS | igual reparto por hilo |

Las 21 instrucciones de diferencia son las del trampolin del loader que se
ejecutan tras su `m5_exit` (`popfq`, los `mov` y el `jmp`) y se contaban como
ROI: la restauracion directa mide solo la aplicacion.

Coste antes del ROI:

| Caso | loader | directa |
|---|---|---|
| `target_app`, AtomicSimpleCPU | 3,6 M instrucciones; gem5 7,3 s en total | 0 instrucciones; gem5 0,8 s en total |
| `smt2` (static + signal_malloc), TimingSimpleCPU | 4,2 M instrucciones por hilo, 45 ms simulados | 0 |
| `x86_mixed_2core.py`, 4 checkpoints | 3,1 M / 9,4 M instrucciones por hilo, 45 ms simulados | 0 |

Tambien probados: `x86_mixed.py --restore auto` (elige directa) con `--pmu`
(los CSV de la PMU salen desde el tick 0), `--warmup` con AtomicSimpleCPU y
SMT-2, y `x86_mixed_2core.py` en ambos modos.

### Arreglos de gem5 necesarios para conmutar de CPU

Al validar el modo loader (y `--warmup`, que tambien conmuta) con un
`gem5.opt` compilado desde `gap_gem5` salieron dos problemas que no son de la
restauracion directa, y que ahora estan arreglados en `gap_gem5`:

- `m5.switchCpus()` abortaba con `Port::takeOverFrom: old->isConnected()`:
  `BaseCPU::takeOverFrom()` traspasa la MMU una vez por hilo, pero los hilos
  SMT comparten una sola MMU, y en SE los puertos de los walkers x86 ni
  siquiera estan conectados. `BaseMMU::takeOverFrom()` solo traspasa ahora
  los puertos conectados (el mismo codigo sigue en `develop` de upstream).
  Sin este arreglo, cualquier config que conmute CPUs x86 en SE aborta en un
  `gem5.opt`; si en altek no pasa, ese gem5 no tiene asserts o tiene cambios
  locales.
- `x86_mixed_2core.py` necesita `suspendContext`/`activateContext`
  exportados a Python en `BaseCPU.py`; su cabecera decia que el arbol estaba
  parcheado, pero el cambio no estaba en el repo. Anadido.

Ademas, `x86_mixed.py` y `x86_mixed_2core.py` fijaban siempre
`mem_mode = "timing"`, y con `--load-cpu atomic` gem5 se negaba a arrancar;
ahora el modo es el de la CPU que arranca.

## Limitaciones

- Solo x86-64 (como todo RMC) y checkpoints de un hilo por proceso.
- Sigue siendo necesario generar sin ASLR y sin AVX (`gen_ckpt.sh`).
- `kvmInSE` (X86KvmCPU en SE) no esta probado con restauracion directa: gem5
  avisa.

## gem5 upstream

Revisado `gem5/gem5` en septiembre de 2026: `stable` = v25.1.0.1 y `develop`
(hasta el 23-09-2026); rama de release `release-staging-v26-0`. **No hay una
funcionalidad equivalente**:

- **ELFies** (`set_se_elfie_workload`, `gem5/resources/elfie.py`): el
  ejecutable ELFie lleva las paginas del checkpoint como segmentos, pero su
  codigo de arranque (que restaura registros y marca el inicio) se sigue
  simulando: es el mismo planteamiento que el loader.
- **Checkpoints nativos de SE** (`m5.checkpoint` / `Process::serialize`):
  solo se pueden crear desde una simulacion de gem5, no a partir de un
  proceso real.

Cambios de upstream posteriores a nuestro 24.1.0.2 que tocan a RMC:

| Cambio | Relevancia |
|---|---|
| Asignador de paginas fisicas con lista libre (#1825, v25.0) y `Process.zeroPages` | las paginas liberadas se ponen a cero al liberarlas, asi que la paginacion bajo demanda de las paginas a cero sigue siendo valida |
| `dup2`/`wait4` corregidos (61cc6b5e, develop) | afecta a la restauracion de FDs del **loader** (usa `dup2`); la directa no pasa por la syscall |
| FSGSBASE en SE (b56b3b2e, develop) | `CR4.FSGSBASE` activado en `initState`; la restauracion directa carga `fs_base` despues, compatible |
| `seconds_since_epoch` en `Process` (#3405, develop) | reloj de SE configurable; util con el vDSO redirigido a syscalls |
| Salidas unificadas por hypercalls (#2983, develop) | `m5_exit` se mantiene por compatibilidad; la restauracion directa ya no depende de el |
| Restauracion dispersa de checkpoints (#2794, develop) | relevante si se convierten checkpoints RMC a checkpoints nativos |

El parche se aplica sin cambios de estructura sobre `develop`: el
`X86_64Process::initState()` de upstream tiene la misma forma
(`X86Process::initState()` -> `argsInit()` -> vsyscall -> registros).

# HANDOFF: validar la restauración directa en altek, unificar versiones y llevarlo a las ramas principales

> **Estado: completado el 29-09-2026.** e2e 30/30 en ambos modos en altek
> (jobs 151470 directa / 151500 loader) con `gap_gem5@8a09b7f`
> (`integration/rmc-direct`); merge a `master` (RMC) y `main` (`gap_gem5`).
> Resultados y la diferencia de IPC con el loader (coloreado de páginas):
> [`docs/RESTAURACION_DIRECTA.md`](docs/RESTAURACION_DIRECTA.md#validacion).
> Pendiente: §7 (instalación única en altek; la clave SSH de altek no tiene
> acceso a `jefemaestro302/gap_gem5`).

Para una instancia (persona o agente) que trabaja **en el PC del usuario**, con
acceso ssh a altek. Afecta a dos repos:

| Repo | Rama con el trabajo | Rama principal |
|---|---|---|
| [`jefemaestro302/real_machine_checkpointing`](https://github.com/jefemaestro302/real_machine_checkpointing) (RMC) | `claude/confident-franklin-kra1vo` | `master` |
| [`jefemaestro302/gap_gem5`](https://github.com/jefemaestro302/gap_gem5) (gem5 24.1.0.2 del GAP) | `claude/confident-franklin-kra1vo` | `main` |

**Objetivo, en este orden:**
1. Inventariar todas las versiones de código que existen (§2) y unificarlas en
   una rama de integración de `gap_gem5` (§3).
2. Compilar esa versión en altek **sin pisar el gem5 que se usa ahora** (§4).
3. Probar en altek los dos modos de restauración, con las pruebas de `test/` y
   con SPEC (§5).
4. Si todo pasa, llevar ambos repos a sus ramas principales (§6) y dejar altek
   con una sola instalación de cada uno (§7).
5. Informar al usuario (§8).

**Regla general:** si algo bloquea o hay que decidir sobre código ajeno (ramas
de otras personas, ficheros de experimentos, cambios locales de altek que no
se entienden), **párate y pregunta al usuario** en lugar de improvisar. Nunca
`git push --force`, nunca reescribir historia de `master`/`main`, nunca borrar
ramas remotas.

---

## 1. Qué se ha hecho (contexto)

**Restauración directa (zero-cycle restore).** Antes, un checkpoint RMC se
restauraba simulando `build/loader`, que reconstruía el proceso con
`mmap`/`memcpy` dentro de gem5 (millones de instrucciones) y marcaba el ROI
con `m5_exit`. Ahora gem5 instala el checkpoint él mismo en
`Process::initState()` y el primer ciclo simulado ya es el ROI. El formato
`.ckpt` no cambia (v2) y el loader sigue disponible (`--restore loader`).
Diseño, uso y revisión de gem5 upstream: [`docs/RESTAURACION_DIRECTA.md`](docs/RESTAURACION_DIRECTA.md).

**Commits** (ambos repos parten de su rama principal actual, así que el merge
puede ser fast-forward):

| Repo | Base | Commits |
|---|---|---|
| gap_gem5 | `main` = `cf36d84f` | `4e7be909` restauración directa (`Process.rmcCheckpoint`/`rmcRemaps`, `src/sim/rmc_checkpoint.{hh,cc}`, hook en `X86_64Process::initState`); `d32b11e1` arreglo de `BaseMMU::takeOverFrom` para conmutar CPUs x86 con SMT y export de `suspendContext`/`activateContext` en `BaseCPU.py` |
| RMC | `master` = `3f67067` | `1e48919` `--restore auto\|direct\|loader` en las configs, lanzadores y e2e; `b37c07a` `mem_mode` según la CPU de arranque, `smt2` válido en ambos modos, documentación |

**Validado en un contenedor (no en altek):** `gem5.opt` compilado desde
`gap_gem5@d32b11e1` + e2e real (`e2e_altek.sh` con `RMC_REMOTE=local` y un
SLURM simulado), pruebas de `test/` (sin SPEC):

- `--restore direct`: **7/7 PASS**. `--restore loader`: **7/7 PASS**.
- Misma salida en ambos modos (checksum de `target_app` = nativo). En directo
  el ROI tiene 21 instrucciones menos: las del trampolín del loader tras su
  `m5_exit`, que antes se contaban como ROI.
- Antes del ROI: `target_app` 3,6 M instrucciones y 7,3 s de gem5 con loader
  frente a 0 instrucciones y 0,8 s en directo; SMT-2 con loader 4,2 M
  instrucciones por hilo y 45 ms simulados, en directo 0.
- También probados: `x86_mixed.py --restore auto` (elige directa) con
  `--pmu`, `--warmup` (AtomicSimpleCPU + SMT-2) y `x86_mixed_2core.py` en
  ambos modos.

**Lo que NO se ha probado:** SPEC (no estaba en el contenedor), altek, y un
gem5 con los arreglos de `fix-smt-wakeup` (§2).

**Indicio de que altek no coincide con GitHub:** con `gap_gem5` tal cual
está en GitHub (`main`), `m5.switchCpus()` aborta en un `gem5.opt`
(`Port::takeOverFrom: old->isConnected()`), y `x86_mixed_2core.py` falla
porque `BaseCPU.py` no exporta `suspendContext`. Sin embargo, la e2e pasaba
30/30 en altek (job 151440) y la cabecera de `x86_mixed_2core.py` dice que
"el árbol está parcheado". Por tanto, el gem5 de altek tiene cambios que no
están en GitHub, o se compiló sin asserts. Hay que averiguarlo en §2.

---

## 2. Inventario de versiones

Rellena una tabla como esta y enséñasela al usuario antes de tocar nada:

| Copia | Dónde | Qué es | Diferencias con la rama de trabajo |
|---|---|---|---|
| RMC `master` | GitHub | base de la rama de trabajo | ninguna salvo los 2 commits |
| RMC en altek | `~/TFM/repositories/real_machine_checkpointing` (clon git, `install_on_altek.sh`) | ¿rama? ¿cambios locales? | `git status`, `git log origin/master..HEAD` |
| RMC en el PC | el clon desde el que se lanza la e2e | ¿rama? ¿cambios locales? | ídem |
| gap_gem5 `main` | GitHub | base de la rama de trabajo | — |
| gap_gem5 `fix-smt-wakeup` | GitHub | 3 commits (junio 2026, Daniel Escribano): arreglos de la O3 en SMT | ver abajo |
| gap_gem5 `executors` | GitHub | scripts de lanzamiento e IDC (marzo 2026); 15 commits por detrás de `main` | ver abajo |
| gap_gem5 en altek | `~/gap_gem5` de cada usuario (`/mnt/beegfs/gap/<usuario>@upvnet.upv.es/gap_gem5`: hay al menos `descrom` y `mapecfer`) | **no es un clon git**: se sube con `scripts/sync/sync_to_altek.sh` (rsync sin `.git/`) | `diff -r` de `gem5/src` y `gem5/configs` contra la rama de trabajo |
| gap_gem5 en el PC | desde donde se lanza `sync_to_altek.sh` | puede tener cambios sin subir | pregunta al usuario dónde está |

Comandos útiles:

```bash
# gap_gem5: ramas de GitHub
git -C gap_gem5 fetch origin
git -C gap_gem5 log --oneline origin/main..origin/fix-smt-wakeup
git -C gap_gem5 diff --stat origin/main...origin/fix-smt-wakeup -- gem5/src gem5/configs
git -C gap_gem5 log --oneline origin/main..origin/executors

# gap_gem5 de altek frente a la rama de trabajo (solo fuentes; excluye build/)
rsync -a --exclude build/ --exclude m5out/ altek1.gap.upv.es:gap_gem5/gem5/src/ /tmp/altek_src/
diff -ru gap_gem5/gem5/src /tmp/altek_src | diffstat     # (o diff -rq)
```

Lo que ya se sabe de las ramas de GitHub:

- **`fix-smt-wakeup`** (`a95da5ff`, `32053e71`, `922d9b2e`): cambia
  `gem5/src/cpu/o3/{commit,cpu,fetch}.{cc,hh}` (livelock por doble borrado de
  instrucciones squashed en SMT, fuga del assert de instcount, despertar de
  hilos SMT y bloqueo en `execve`), más `scripts/sync/sync_to_altek.sh` y un
  test. Además toca **unos 1450 ficheros de `benchmarks/gap_bench/experiments/`,
  `scripts/python/manager_workloads/` y `scripts/python/venv/`**, pero solo
  cambia el prefijo de ruta `mapecfer@...` → `descrom@...` (salidas de
  experimentos regeneradas y shebangs del venv). **No se solapa** con los
  ficheros de la restauración directa.
- **`executors`**: scripts de SLURM y de gráficas (`scripts/bash/X86/`,
  `scripts/python/priority_idc_investigation/`...). No toca `gem5/src`.

---

## 3. Unificación de `gap_gem5`

Crea una rama de integración desde la rama de trabajo, que ya contiene `main`:

```bash
cd gap_gem5
git checkout -b integration/rmc-direct origin/claude/confident-franklin-kra1vo
```

1. **Arreglos de `fix-smt-wakeup`**: incorpora los cambios de `gem5/src`
   (y `scripts/sync/sync_to_altek.sh` y el test si el usuario quiere). **Pregunta
   al usuario** qué hacer con los ~1450 ficheros de experimentos/venv: lo
   natural es no arrastrarlos (son salidas regeneradas con otro usuario, y el
   venv no debería estar versionado), así que probablemente toque traer solo
   las fuentes, p. ej.
   `git checkout origin/fix-smt-wakeup -- gem5/src/cpu/o3 scripts/sync benchmarks/gap_bench/experiments/test_smt_wakeup.sh`
   y un commit que cite los tres originales. Si prefiere un merge completo,
   `git merge origin/fix-smt-wakeup`.
2. **`executors`**: pregunta al usuario si entra ahora o se queda como rama
   aparte. Si entra: `git merge origin/executors` y resolver conflictos (van
   15 commits por detrás de `main`).
3. **Cambios que solo están en altek** (resultado del `diff` de §2): por cada
   fichero, decide con el usuario si se sube, se descarta o ya está cubierto.
   Casos esperables:
   - export de `suspendContext`/`activateContext` en `src/cpu/BaseCPU.py`:
     ya está en la rama de trabajo (`d32b11e1`);
   - algo en `src/arch/generic/mmu.cc` o `src/cpu/base.cc` que evite el
     assert de `switchCpus()`: comparar con `d32b11e1` y quedarse con uno;
   - cualquier otro cambio en `src/sim/syscall_emul.*` (manager), `src/cpu/o3/*`
     (PMU): respetar el de altek salvo que el usuario diga otra cosa.
4. Compila en local si puedes (ver §4 para los detalles de compilación) y
   sube la rama: `git push -u origin integration/rmc-direct`.

En RMC no hay nada que unificar salvo cambios locales de altek o del PC
(§2): si los hay, llévalos a la rama de trabajo con el usuario.

---

## 4. Compilar en altek sin pisar el gem5 actual

La e2e usa por defecto `~/gap_gem5/gem5/build/X86/gem5.opt`, y puede haber
experimentos del usuario u otras personas usándolo. Compila la integración
**en un directorio aparte**:

```bash
ssh altek1.gap.upv.es
GIT_LFS_SKIP_SMUDGE=1 git clone -b integration/rmc-direct https://github.com/jefemaestro302/gap_gem5 ~/gap_gem5_rmc
cd ~/gap_gem5_rmc/gem5
scons --version          # 4.7 funciona; 4.11 rompe los tests de configuración (ver abajo)
scons build/X86/gem5.opt -j"$(nproc)" --ignore-style
```

Pregunta al usuario si en altek se compila en el nodo de login o con un
trabajo SLURM, y sigue esa costumbre.

- **scons 4.11** rompe la configuración de gem5 24.1: todos los tests de
  enlace fallan con `Syntax error: "(" unexpected` y acaba en
  `Did not find needed zlib`. Con `pip install --user "scons==4.7.0"` funciona.
- Compilación completa con 4 núcleos: ~1 h. Solo cambian unos pocos `.cc`
  respecto a `main`, pero en un directorio nuevo se compila todo.
- Comprobación rápida de que es el gem5 correcto:
  `strings build/X86/gem5.opt | grep -c rmcCheckpoint` (> 0).
- **Ojo con el manager:** `exitImpl` (`src/sim/syscall_emul.cc`) cambia el
  comportamiento del `exit` si existe `/tmp/.gem5_sentinel` en el nodo. Si una
  prueba se queda colgada al terminar el programa, mira si ese fichero existe.

---

## 5. Pruebas en altek

Desde el PC, con el repo RMC en `claude/confident-franklin-kra1vo` (o en la
rama con lo que hayas unificado en §3) y el gem5 nuevo:

```bash
cd <repo RMC>
git fetch origin && git checkout claude/confident-franklin-kra1vo && git pull
# Ruta ABSOLUTA en altek: e2e_altek.sh la comprueba entre comillas simples, sin expandir ~
export RMC_GEM5_REMOTE="$(ssh altek1.gap.upv.es 'printf %s "$HOME"')/gap_gem5_rmc/gem5/build/X86/gem5.opt"
launch_scripts/e2e_altek.sh --restore direct --spec all 2>&1 | tee e2e_direct_$(date +%s).txt
launch_scripts/e2e_altek.sh --restore loader --spec all 2>&1 | tee e2e_loader_$(date +%s).txt
```

Antes, las comprobaciones de siempre: SPEC compilado sin AVX en
`<repo>/specs/benchspec/CPU` (si falta: `./generate_all_spec_checkpoints.sh
--build-only`, en Docker; la guía detallada de recompilación, con label,
config, compiladores y problemas típicos, está en el handoff anterior:
`git show 3f67067:HANDOFF.md`, §1b), `setarch -R true` en el PC (fuera de Docker),
`ssh altek1.gap.upv.es 'sinfo -s'` con la partición `compute`. Guía de la
e2e y de cada prueba: [`docs/VERIFICACION_GEM5.md`](docs/VERIFICACION_GEM5.md).

**Qué tiene que salir:**

| Ejecución | Esperado | Referencia |
|---|---|---|
| `--restore direct --spec all` | `RESULTADO: EXITO`, 7 pruebas + 23 SPEC = **30/30** | nuevo |
| `--restore loader --spec all` | **30/30**, igual que el job 151440 del 29-09-2026 | regresión del modo loader con el gem5 unificado |

En directo, cada `gem5.log` tiene que mostrar
`RMC: ... regions restored (...)`, `process N restored at the ROI` y
`Checkpoint instalado en initState` o `instalados en initState`, y ningún
`[loader]`.

**Comparación entre modos** (para el informe, no bloquea el merge):

- Instrucciones de ROI: en directo, ~21 menos por checkpoint (trampolín).
- Tiempo: columna `(Ns)` de cada línea de `summary.txt`: en directo tiene
  que bajar (desaparece la carga).
- Un par de SPEC en O3 en ambos modos, para ver que el IPC es coherente
  (en altek, desde `~/TFM/repositories/real_machine_checkpointing` con la
  rama de trabajo y `GEM5_BIN=~/gap_gem5_rmc/gem5/build/X86/gem5.opt`; los
  checkpoints `~/checkpoints/dump_<b>_r_noavx.ckpt` los deja
  `regenerate_ckpt_noavx.sh --upload`, o usa los de `~/TFM/rmc_e2e/<ID>/ckpt/`):
  ```bash
  RMC_RESTORE=loader launch_scripts/run_mixed.sh mcf_loader 10000000 timing ~/checkpoints/dump_mcf_r_noavx.ckpt
  RMC_RESTORE=direct launch_scripts/run_mixed.sh mcf_direct 10000000 timing ~/checkpoints/dump_mcf_r_noavx.ckpt
  RMC_RESTORE=direct RMC_WARMUP=5000000 launch_scripts/run_mixed.sh mcf_warm 10000000 atomic ~/checkpoints/dump_mcf_r_noavx.ckpt
  launch_scripts/parse_roi_stats.py ~/TFM/m5out/mcf_loader ~/TFM/m5out/mcf_direct ~/TFM/m5out/mcf_warm
  ```
  Pequeñas diferencias de IPC en
  ROI cortos son normales: con el loader las cachés arrancan con lo que dejó
  su `memcpy` y en directo arrancan frías (`--warmup` lo iguala).
- SMT del TFM: `x86_mixed_2core.py` en ambos modos, que antes necesitaba
  el parche de `BaseCPU.py`.

**Diagnóstico** (además de la tabla de `docs/VERIFICACION_GEM5.md`):

| Síntoma | Causa probable | Qué hacer |
|---|---|---|
| `--restore direct: este gem5 no tiene Process.rmcCheckpoint` | se está usando el gem5 viejo | revisar `RMC_GEM5_REMOTE` / `GEM5_BIN` |
| `fatal: RMC: ... bad magic` / `format version` | checkpoint v1 o corrupto | regenerar con `gen_ckpt.sh` |
| `fatal: RMC: ... lies outside the file` | checkpoint truncado | regenerar |
| `warn: RMC: failed to restore fd N` / `the checkpoint ran in X but the process cwd is Y` | falta un remapeo PC→altek | igual que con el loader: `<ckpt>.remap`, `LOADER_OPTS` |
| `panic: Someone allocated physical memory at VA ... without creating a VMA` | algo mapeó páginas fuera de `MemState` tras la restauración | **bug de la restauración directa**: anota el checkpoint y la traza con `--debug-flags=Rmc,Vma` y avisa al usuario |
| `Port::takeOverFrom: old->isConnected()` al conmutar | gem5 sin `d32b11e1` | usar el gem5 de la integración |
| `object 'X86O3CPU' has no attribute 'suspendContext'` | gem5 sin el export de `BaseCPU.py` | ídem |
| falla en directo pero pasa con loader (o al revés) | diferencia real entre modos | **no hagas merge**; `run_st_timing.sh` del checkpoint en ambos modos con `--debug-flags=Rmc` y `SyscallVerbose`, y avisa al usuario |

---

## 6. Llevarlo a las ramas principales

**Solo si** las dos e2e dan 30/30 y el usuario ha visto el inventario (§2)
y las decisiones de unificación (§3). Si algo falla, no hagas merge: informa.

```bash
# gap_gem5: main <- integration/rmc-direct
cd gap_gem5
git fetch origin
git checkout main && git pull --ff-only origin main
git merge --ff-only integration/rmc-direct || git merge --no-ff integration/rmc-direct
#   (fast-forward si main no se ha movido; si no, merge commit, nunca rebase)
git push origin main

# RMC: master <- claude/confident-franklin-kra1vo (+ lo unificado)
cd <repo RMC>
git checkout master && git pull --ff-only origin master
git merge --ff-only claude/confident-franklin-kra1vo || git merge --no-ff claude/confident-franklin-kra1vo
git push origin master
```

- Si `main` o `master` avanzaron mientras tanto, el merge commit necesita
  volver a compilar y a pasar al menos la e2e sin SPEC antes del push.
- Si el push directo a la rama principal está protegido, abre un PR desde la
  rama de integración con el resumen de §8 y avisa al usuario.
- No borres `claude/confident-franklin-kra1vo`, `fix-smt-wakeup` ni
  `executors`: que lo decida el usuario.

## 7. Dejar altek con una sola instalación

- RMC: `launch_scripts/install_on_altek.sh master` (clona o actualiza
  `~/TFM/repositories/real_machine_checkpointing` y compila loaders y
  `libckpt.so`).
- gem5: pregunta al usuario cómo quiere quedarse:
  a) sustituir su `~/gap_gem5` por el clon git de `main` (recomendado: así
     altek y GitHub dejan de divergir; `sync_to_altek.sh` deja de hacer falta
     o se usa solo para probar cambios), o
  b) mantener el rsync y sincronizar `main` desde el PC.
  En ambos casos, recompilar y comprobar
  `strings .../gem5.opt | grep -c rmcCheckpoint`. No toques el `~/gap_gem5`
  de otros usuarios (`mapecfer`...).

## 8. Qué devolver al usuario

- Tabla del inventario (§2) y qué se decidió con cada diferencia (§3).
- Commit/rama de la integración de `gap_gem5` y cómo se compiló en altek.
- Para cada e2e: comando, `<ID>`, job de SLURM, código de salida y
  `summary.txt` completo; por cada `FAIL`, la causa (tablas de §5 y de
  `docs/VERIFICACION_GEM5.md`) y ~30 líneas relevantes de su `gem5.log`.
- Tabla por benchmark SPEC: PASS/FAIL en cada modo, instrucciones de ROI y
  segundos en cada modo.
- La comparación de IPC de `run_mixed.sh` (§5).
- Si se hizo el merge: hashes de `main` y `master` resultantes. Si no, por qué.
- Estado final de altek (§7).

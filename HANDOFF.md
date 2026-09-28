# HANDOFF: validar el flujo RMC con SPEC en altek

Para una instancia (persona o agente) que trabaja **en el PC del usuario**, con
este repo en la rama `bug-fixes`, y que tiene que comprobar que los
checkpoints de SPEC se generan en el PC y se restauran y simulan en gem5 en
altek. Lo que importa son las SPEC; las pruebas de `test/` acompañan porque
aíslan cada mecanismo y ayudan a diagnosticar si una SPEC falla.

## Estado

- La rama `bug-fixes` corrige los bugs de [`docs/BUG_FIXES.md`](docs/BUG_FIXES.md)
  y unifica la generación: **todo** checkpoint sale de
  `launch_scripts/gen_ckpt.sh`, y los benchmarks se definen solo en
  `launch_scripts/benchmarks.sh` (hoy `mcf` y `perlbench`).
- `launch_scripts/e2e_altek.sh` hace todo desde el PC: compila, genera,
  sube, lanza el sbatch, espera y da el veredicto.
- Validado fuera de altek: pruebas nativas (16/16) y el orquestador con
  SLURM y gem5 simulados. **Nunca se ha ejecutado contra altek ni contra gem5
  real.** Esta es la primera vez: cualquier fallo es información nueva, no un
  problema conocido.
- Formato de checkpoint v2: los `.ckpt` antiguos (v1) se rechazan. El e2e
  genera los suyos.

## Docker: qué sí y qué no

| Paso | Dónde | Por qué |
|---|---|---|
| Compilar SPEC sin AVX | **Docker** (`gem5_noavx_env`, `specs/config/gem5_noavx.cfg`) | toolchain reproducible; nunca se compila en el clúster |
| Generar checkpoints | **Host del PC, fuera de Docker** | el seccomp de Docker no deja desactivar ASLR (`setarch -R`) |
| Simular | altek (gem5 vía SLURM) | |

El e2e **no usa Docker**: da por hecho que SPEC ya está compilado en
`<repo>/specs/benchspec/CPU` con los directorios de ejecución preparados.

## 1. Comprobaciones previas (en el PC)

```bash
cd <repo> && git fetch origin && git checkout bug-fixes && git pull origin bug-fixes
uname -m                                   # x86_64
setarch -R true && echo ok                 # si falla: estás dentro de Docker
for t in gcc make python3 rsync ssh readelf objdump; do command -v $t >/dev/null || echo "falta $t"; done
ssh altek1.gap.upv.es 'echo ok; ls ~/gap_gem5/gem5/build/X86/gem5.opt; sinfo -s'
ls specs/benchspec/CPU/505.mcf_r/run/run_base_train_test_compilacion-m64.0000/mcf_r_base.test_compilacion-m64 \
   specs/benchspec/CPU/500.perlbench_r/run/run_base_train_test_compilacion-m64.0000/perlbench_r_base.test_compilacion-m64
```

- **ssh:** si pide contraseña se pide una vez; la conexión se reutiliza. Para
  un agente sin terminal interactiva hace falta una clave ssh ya configurada.
- **Partición:** el script usa `compute`. Si `sinfo -s` no la lista, pasa
  `--partition <otra>`.
- **gem5 en otra ruta:** exporta `RMC_GEM5_REMOTE=/ruta/gem5.opt`.
- **Si faltan los binarios o directorios SPEC,** compílalos en Docker
  (necesita la imagen `gem5_noavx_env` y el árbol SPEC instalado en `specs/`):

  ```bash
  ./generate_all_spec_checkpoints.sh
  ```

  Ese script compila y prepara en Docker y después genera en el host. Los
  checkpoints que deja no hacen falta para el e2e.

## 2. Lanzar

```bash
launch_scripts/e2e_altek.sh --spec all 2>&1 | tee e2e_$(date +%s).txt; echo "exit=${PIPESTATUS[0]}"
```

- Para **solo SPEC,** sin las pruebas de `test/`: añade `--no-tests`.
- Para una ROI más larga: `--spec-insts 100000000`, y sube `--time` si hace
  falta.
- Duración aproximada: la generación tarda unos segundos por benchmark (mcf
  se vuelca a los 5 s, perlbench a los 3 s). La subida lleva varios cientos
  de MB. Las pruebas de `test/` pueden ocupar hasta ~1-2 h en CPU atomic.
- **Si se corta la terminal,** el trabajo sigue en altek. Para
  reengancharse: `launch_scripts/e2e_altek.sh --attach <ID>`, con el `<ID>` =
  `e2e_runs/<ID>` que se imprimió al lanzar.

Aviso: con `--spec`, el script sube los directorios de ejecución del PC a
`~/spec_cpu_2017/benchspec/CPU/<bench>/run/...` en altek y sobrescribe los
ficheros con el mismo nombre. Si ahí hay algo que conservar, usa otro destino
con `SPEC_REMOTE_DIR=...`.

## 3. Interpretar

Última línea:

| Salida | Código | Significado |
|---|---|---|
| `RESULTADO: EXITO` | 0 | todas las pruebas pasan: el flujo funciona en altek |
| `RESULTADO: FALLO` | 1 | alguna prueba falla; ver el resumen y `e2e_runs/<ID>/results/<prueba>/gem5.log` |
| `RESULTADO: ERROR DE PREPARACION: ...` | 2 | no se llegó a simular; el mensaje dice qué paso falló |

`e2e_runs/<ID>/results/summary.txt` tiene una línea `PASS`/`FAIL` por
prueba. Un `spec_<b>` que pasa muestra
`Instrucciones de ROI ejecutadas: 10000000`.

Qué comprueba cada prueba: [`docs/VERIFICACION_GEM5.md`](docs/VERIFICACION_GEM5.md).

## 4. Diagnóstico de fallos

Revisa en este orden:
1. `e2e_runs/<ID>/ckpt/<ckpt>.log`: salida de la generación.
2. `.inspect`: loader recomendado, `heap_end`, cwd y FDs.
3. `.meta`: condiciones de generación.
4. `results/<prueba>/gem5.log`.

| Síntoma | Causa probable | Qué hacer |
|---|---|---|
| `setarch -R no funciona` | ejecutando dentro de Docker | lanzarlo en el host |
| `gen_ckpt`: el binario tiene AVX/BMI2 | SPEC compilado sin `gem5_noavx.cfg` | recompilar en Docker (`generate_all_spec_checkpoints.sh`) |
| `[gen] FALLO ...: el programa termino sin generar el checkpoint` | `BENCH_NS` mayor que la duración de la ejecución, o el benchmark falló (ver `.log` y `.stdout`) | bajar `BENCH_NS` en `benchmarks.sh` |
| `no existe .../run/run_base_train_...` | falta `runcpu --action=setup` | ídem, Docker |
| `sbatch fallo` / partición inválida | partición | `--partition` según `sinfo` |
| `el loader no llego al ROI` + `[loader] FATAL ... overlap` | checkpoint generado con ASLR, o loader equivocado | mirar `.meta` (`RMC_ASLR=off`) y la línea `**** Loader: ...` de gem5.log |
| `[loader] WARNING: failed to restore fd ...` o `cannot chdir`, y luego falla el programa | un fichero de entrada no está en altek o la ruta no se remapeó | comparar los FDs y el `cwd=` de `.inspect` con `remapeos:` en `summary.txt` |
| `panic: Unrecognized/invalid instruction` | camino AVX/SSE4 en glibc o en el binario | `.meta` debe tener `RMC_TUNABLES`; buscar la instrucción en el PC del panic con `objdump` |
| `ROI terminado: 'exiting with last active thread context'` en SPEC | el benchmark murió o acabó dentro del ROI | leer la salida del programa en `gem5.log` (errores de fichero o `cwd`) |
| `timeout` en el loader | brk movido muy lejos (loader no PIE con heap PIE) | comprobar que eligió `loader_pie` (bug 4) |
| falla `static_malloc` o `smt2` con errores de heap | recorte del brk desde el trampolín en gem5: la parte que menos se ha podido probar sin gem5 | anotar el log; reproducir con `gem5dbg` de `docs/VERIFICACION_GEM5.md` (traza `SyscallVerbose` de `brk`) |

En altek todo queda en `~/TFM/rmc_e2e/<ID>/`: `repo/`, `ckpt/`, `results/` y
`slurm-*.out`.

## 5. Qué no hacer

- No compilar SPEC en altek ni generar checkpoints en Docker.
- No generar a mano con `LD_PRELOAD=...`; siempre con `gen_ckpt.sh`.
- No reutilizar checkpoints v1 de `~/checkpoints`; se regeneran con
  `launch_scripts/regenerate_ckpt_noavx.sh all`.
- No versionar `e2e_runs/`: está en `.gitignore`.
- Si hace falta un cambio de código, en una rama nueva desde `bug-fixes`, no
  en `master`.

## 6. Qué devolver al usuario

- Comando lanzado, `<ID>`, job de SLURM y código de salida.
- `summary.txt` completo.
- Por cada `FAIL`: la causa según la tabla de la sección 4 y las ~30 líneas
  relevantes de su `gem5.log`.
- Si todo pasa: las instrucciones de ROI de cada `spec_<b>` y el tiempo total.

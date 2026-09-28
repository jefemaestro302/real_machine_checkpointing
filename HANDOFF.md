# HANDOFF: validar el flujo RMC con SPEC en altek

Para una instancia (persona o agente) que trabaja **en el PC del usuario**, con
este repo en la rama `bug-fixes`, y que tiene que comprobar que los
checkpoints de SPEC se generan en el PC y se restauran y simulan en gem5 en
altek. Lo que importa son las SPEC; las pruebas de `test/` acompañan porque
aíslan cada mecanismo y ayudan a diagnosticar si una SPEC falla.

**Orden de trabajo:**
1. Comprobaciones previas (§1).
2. Recompilar SPEC en Docker (§1b).
3. Lanzar el e2e con `--spec all` (§2).
4. Interpretar el resultado (§3) y diagnosticar los fallos (§4).
5. Informar al usuario (§6).

Si algo bloquea (falta SPEC instalado, falta la clave ssh, la partición no
existe…), párate y pregunta al usuario en lugar de improvisar.

## Estado

- La rama `bug-fixes` corrige los bugs de [`docs/BUG_FIXES.md`](docs/BUG_FIXES.md)
  y unifica la generación: **todo** checkpoint sale de
  `launch_scripts/gen_ckpt.sh`, y los benchmarks se definen solo en
  `launch_scripts/benchmarks.sh`.
- **Cubre todas las SPEC rate** (`NNN.*_r`, intrate + fprate) que estén
  compiladas y preparadas. El comando de cada benchmark se lee del
  `speccmds.cmd` que deja `runcpu --action=setup` en su directorio de
  ejecución; si hay varias invocaciones, se usa la primera.
  - `mcf` y `perlbench` tienen el instante del volcado medido con perf; el
    resto se vuelca a los 2 s (`RMC_SPEC_NS`). Para probar que el flujo
    funciona basta; para medir, hay que ajustar ese instante por benchmark.
  - Las speed (`_s`) no entran: usan OpenMP y el checkpoint es de un solo
    hilo.
- `launch_scripts/e2e_altek.sh` hace todo desde el PC: compila, genera,
  sube, lanza un array SLURM (una tarea por prueba, 8 a la vez), espera y da
  el veredicto. Un benchmark que no se pueda generar no para los demás:
  aparece como `FAIL` con el motivo.
- Validado fuera de altek: pruebas nativas (16/16) y el orquestador con
  SLURM y gem5 simulados. **Nunca se ha ejecutado contra altek ni contra gem5
  real.** Esta es la primera vez: cualquier fallo es información nueva, no un
  problema conocido.
- Formato de checkpoint v2: los `.ckpt` antiguos (v1) se rechazan. El e2e
  genera los suyos.

## Docker: qué sí y qué no

| Paso | Dónde | Por qué |
|---|---|---|
| Compilar SPEC sin AVX | **Docker** (`gem5_noavx_env` de `docker/Dockerfile.spec`, `specs/config/gem5_noavx.cfg`) | toolchain reproducible; nunca se compila en el clúster |
| Generar checkpoints | **Host del PC, fuera de Docker** | el seccomp de Docker no deja desactivar ASLR (`setarch -R`) |
| Simular | altek (gem5 vía SLURM) | |

Solo hay una forma de compilar SPEC, y es en Docker:
`generate_all_spec_checkpoints.sh`. El e2e **no usa Docker**: da por hecho
que SPEC ya está compilado en `<repo>/specs/benchspec/CPU` con los
directorios de ejecución preparados.

## 1. Comprobaciones previas (en el PC)

```bash
# repo (si no está clonado: git clone https://github.com/jefemaestro302/real_machine_checkpointing)
cd <repo> && git fetch origin && git checkout bug-fixes && git pull origin bug-fixes
uname -m                                   # x86_64
setarch -R true && echo ok                 # si falla: estás dentro de Docker
for t in gcc make python3 rsync ssh readelf objdump; do command -v $t >/dev/null || echo "falta $t"; done
ssh altek1.gap.upv.es 'echo ok; ls ~/gap_gem5/gem5/build/X86/gem5.opt; sinfo -s'
ls -d specs/benchspec/CPU/*_r/run/run_base_train_test_compilacion-m64.0000   # benchmarks preparados
```

- **ssh:** si pide contraseña se pide una vez; la conexión se reutiliza. Para
  un agente sin terminal interactiva hace falta una clave ssh ya configurada.
- **Partición:** el script usa `compute`. Si `sinfo -s` no la lista, pasa
  `--partition <otra>`.
- **gem5 en otra ruta:** exporta `RMC_GEM5_REMOTE=/ruta/gem5.opt`.

## 1b. Recompilar SPEC (en el PC, con Docker)

Hazlo siempre antes del e2e, y en todo caso si faltan benchmarks, si alguno
falla por AVX o si los binarios son de antes de esta rama. Así todos salen
de la misma toolchain y la misma config.

**Datos:**

| Qué | Valor |
|---|---|
| Árbol SPEC CPU2017 | instalado en `<repo>/specs/`: `specs/shrc`, `specs/bin/`, `specs/benchspec/CPU/`. No se versiona (licencia) |
| Config | `specs/config/gem5_noavx.cfg` (versionada) |
| Label | `test_compilacion`, más `-m64`; debe coincidir con `RMC_SPEC_LABEL` |
| Tuning | `base`, `-O3 -march=x86-64 -mtune=generic`: sin AVX, con 1 copia |
| Carga | `train` (`RMC_SPEC_SIZE`) |
| Directorio de ejecución resultante | `specs/benchspec/CPU/<NNN.bench_r>/run/run_base_train_test_compilacion-m64.0000/`, con el binario, las entradas y `speccmds.cmd` |
| Compiladores | `gcc-11`, `g++-11` y `gfortran-11` en `/usr/bin`, los que pide la config |
| Imagen Docker | `gem5_noavx_env:latest`, de `docker/Dockerfile.spec` (Ubuntu 22.04). El script la construye si no existe |
| Host | Linux x86-64 con glibc ≥ 2.35 (Ubuntu 22.04 o posterior): los binarios son dinámicos y se ejecutan fuera del contenedor al generar |
| Qué compila `all` | las suites `intrate` y `fprate`: los ~23 benchmarks rate |

**Comandos:**

```bash
docker info >/dev/null && echo docker-ok      # Docker sin sudo (usuario en el grupo docker)
ls specs/shrc specs/config/gem5_noavx.cfg     # SPEC instalado
./generate_all_spec_checkpoints.sh --build-only            # todas las rate (horas)
./generate_all_spec_checkpoints.sh --build-only lbm xz     # solo algunas
```

- **Qué hace:** construye la imagen si falta y, dentro de ella, ejecuta
  `runcpu --action=build` y `runcpu --action=setup --size=train`. Corre con el
  usuario del host (`--user`) para que los ficheros de `specs/` sean suyos.
- **Resultado:** al final imprime `Preparados: ...` y `SIN preparar: ...`.
  Un benchmark que no compila no para a los demás; su log está en
  `specs/benchspec/CPU/<b>/build/build_base_test_compilacion-m64.0000/make.out`.
- **Sin `--build-only`,** además genera checkpoints en el host. No hace falta
  para el e2e, que genera los suyos.
- **Si falla por permisos en `specs/`** (restos de compilaciones anteriores
  hechas como root): `sudo chown -R "$USER": specs`.
- **Si SPEC no está instalado en `specs/`,** hay que instalarlo desde la ISO
  de SPEC CPU2017, y eso lo tiene que hacer el usuario, porque la ISO es suya:

  ```bash
  mount -o loop cpu2017.iso /mnt
  /mnt/install.sh -d <repo>/specs
  ```

  Después comprueba que `specs/config/gem5_noavx.cfg` sigue ahí (`git checkout specs/config`).
- **Nunca se ha probado:** `docker/Dockerfile.spec` es nuevo y no se ha
  construido. Si falla la construcción o falta un paquete, arréglalo en ese
  Dockerfile y en la misma rama.
- **Si el PC ya tiene una imagen `gem5_noavx_env` de antes,** el script la
  reutiliza. Para usar la del repo: `docker rmi gem5_noavx_env:latest`.

Comprobación rápida de un binario:

```bash
objdump -d specs/benchspec/CPU/505.mcf_r/run/run_base_train_test_compilacion-m64.0000/mcf_r_base.test_compilacion-m64 \
  | grep -cE '%ymm|%zmm|vzeroupper|bextr|shlx|sarx|shrx'   # tiene que dar 0
```

## 2. Lanzar

```bash
launch_scripts/e2e_altek.sh --spec all 2>&1 | tee e2e_$(date +%s).txt; echo "exit=${PIPESTATUS[0]}"
```

- `--spec all` = todas las rate preparadas. Para un subconjunto:
  `--spec mcf,lbm,xz`.
- Para **solo SPEC,** sin las pruebas de `test/`: añade `--no-tests`.
- **Recursos por tarea SLURM:** `--time` (03:00:00), `--mem` (16G) y
  `--parallel` (8 tareas a la vez).
- Para una ROI más larga: `--spec-insts 100000000`, y sube `--time` si hace
  falta.
- Duración aproximada:
  - generación: unos segundos por benchmark (el volcado es a los 2-5 s);
  - subida: con ~23 benchmarks puede pasar de varios GB de checkpoints;
  - cada tarea: carga del checkpoint más 10 M instrucciones en CPU atomic,
    minutos. Las pruebas de `test/` son las más largas (hasta ~1 h).
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
| `FAIL spec_X: no se genero el checkpoint en el PC: ...` | el motivo viene detrás; el detalle está en `ckpt/gen_X.err` y `ckpt/dump_X_r_noavx.ckpt.log` | según el motivo (filas siguientes) |
| `[gen] FALLO ...: el programa termino sin generar el checkpoint` | la primera invocación del benchmark dura menos de 2 s, o el benchmark falló (ver `.log` y `.stdout`) | bajar el instante del volcado para ese benchmark con un caso en `bench_def()` de `benchmarks.sh` |
| `FAIL X: sin resultado (la tarea SLURM no termino...)` | la tarea murió por falta de memoria o de tiempo | `results/slurm-<job>_<n>.out`; relanzar con más `--mem` o `--time` |
| `benchmark desconocido o sin preparar` / `no hay benchmarks rate preparados` | ese benchmark no está compilado o preparado | `generate_all_spec_checkpoints.sh --build-only <b>` (Docker) |
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
- Una tabla por benchmark SPEC: generado sí/no, PASS/FAIL y motivo. Incluye
  los que no llegaron a entrar: la línea `sin directorio de ejecucion
  preparado` del e2e y los que no compilaron en Docker.
- Si todo pasa: las instrucciones de ROI de cada `spec_<b>` y el tiempo total.

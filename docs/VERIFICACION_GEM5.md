# Verificacion de los arreglos en gem5

Complemento de [`BUG_FIXES.md`](BUG_FIXES.md). Las pruebas nativas
(`test/run_native_tests.sh`) cubren lo que se reproduce en el host; esta guia
cubre lo que solo se ve dentro de gem5 SE: program break, vDSO, mapeo del
`.ckpt`, FDs, SMT y la frontera del ROI.

Todo se lanza desde el repo en el cluster (tras `launch_scripts/install_on_altek.sh`).
Rutas y binarios: `launch_scripts/_common.sh` (`GEM5_BIN`, `CKPT_DIR`, `OUT_BASE`).

## 0. Preparacion

```bash
make                                # build/loader, build/loader_pie, build/libckpt.so, ...
W=$HOME/TFM/rmc_checks; mkdir -p $W; cd $W
R=~/TFM/repositories/real_machine_checkpointing
# Programas de prueba sin AVX (gem5 SE no implementa AVX)
F="-O2 -mno-avx -mno-avx2 -mno-sse4.1 -mno-sse4.2"
gcc $F -o test_signal_malloc $R/test/test_signal_malloc.c
gcc $F -o test_redzone       $R/test/test_redzone.c
gcc -O1 -mno-avx -o test_vdso $R/test/test_vdso.c
NOAVX="glibc.cpu.hwcaps=-SSE4_2,-SSE4_1,-SSSE3,-AVX,-AVX2,-AVX512F"
dump() {  # dump <prog> <ns>  ->  <prog>.ckpt   (setarch envuelve a env)
    setarch -R env GLIBC_TUNABLES=$NOAVX LD_PRELOAD=$R/build/libckpt.so \
        CKPT_AFTER_NS=$2 CKPT_OUTPUT=$W/$1.ckpt ./$1 >/dev/null
}
st() {    # st <ckpt> <maxinsts> [debug-flags]: CPU simple, trazas en $W/<tag>
    OUT_BASE=$W $R/launch_scripts/run_st_timing.sh "$1" "$2" atomic
}
```

Cada ejecucion imprime `**** Loader: .../loader_pie ****` (o `loader`): es la
eleccion automatica de `gem5_configs/rmc_common.py`. Para ver el porque:
`python3 $R/tools/ckpt_inspect.py X.ckpt | grep heap_end`.

Para las comprobaciones con trazas de syscalls se lanza gem5 a mano:

```bash
$GEM5_BIN --outdir=$W/dbg --debug-flags=SyscallVerbose --debug-file=sys.trace \
    $R/gem5_configs/x86_st_timing.py --cmd=$R/build/loader \
    --options="$W/X.ckpt" --cpu=atomic --maxinsts=50000000
```

## 1. Frontera del ROI y restauracion basica (bugs 1, 3, 5, 7, 8)

```bash
cd $W && setarch -R $R/build/target_app $W/t.ckpt 2>&1 | grep checksum
st $W/t.ckpt 50000000
```

Esperado:
- `Loader terminado: 'm5_exit instruction encountered'`: el loader llega a la
  frontera (el `m5_exit` esta ahora en el trampolin; con `--native` no se ejecuta).
- En la salida del objetivo, el **mismo** `checksum=0x...` que en la ejecucion
  nativa.
- Ningun `FATAL` del loader. Si aparece `overlaps the loader image/heap`, el
  checkpoint se genero con ASLR y el heap cayo encima del loader: regenerar con
  `setarch -R` (bug 3/4: antes esto se machacaba en silencio).

Para ver que el `.ckpt` ya no se mapea sobre las librerias (bug 3): en
`sys.trace` el `mmap` del fichero del checkpoint devuelve una direccion
`>= 0x100000000000` y, justo antes del `m5_exit`, hay un `munmap` de esa
direccion.

## 2. Red zone (bug 1)

```bash
dump test_redzone 300000000
st $W/test_redzone.ckpt 20000000000      # deja terminar el programa
```

Esperado: `REDZONE OK`. (Con el loader antiguo: `REDZONE CORRUPT` en nativo el
100 % de las veces.) Nota: son ~1e9 instrucciones; en atomic es rapido.

## 3. Program break y malloc (bug 4)

Es el arreglo que mas depende de gem5. Dos casos:

**PIE (heap por encima del loader, SPEC):**
```bash
dump test_signal_malloc 500000000
$GEM5_BIN --outdir=$W/brk_pie --debug-flags=SyscallVerbose --debug-file=sys.trace \
    $R/gem5_configs/x86_st_timing.py --cmd=$R/build/loader \
    --options="$W/test_signal_malloc.ckpt" --cpu=atomic --maxinsts=2000000000
grep -E "brk" $W/brk_pie/sys.trace | head
```
Esperado:
- `Loader: .../loader_pie`.
- El primer `brk` (del loader, antes del `m5_exit`) devuelve exactamente el
  final del `[heap]` del checkpoint (`ckpt_inspect.py ... | grep heap_end`).
- Los `brk` posteriores (del programa, durante el ROI) **crecen desde ese
  valor** y devuelven lo pedido.
- El programa no aborta con `double free or corruption` (si llega a terminar,
  imprime `MALLOC OK`).
- Sin el arreglo: los `brk` del ROI devuelven el break del loader
  (`0x200xxxxx`) y el programa aborta en el primer recorte del heap.

**No PIE (heap por debajo del loader):** `test/test_static_malloc.c` vuelca
con `ckpt_dump()` y despues hace crecer y recortar el heap.
```bash
gcc -O2 -static -no-pie -fno-stack-protector -mno-avx -o test_static_malloc \
    $R/test/test_static_malloc.c $R/src/dumper.c $R/src/dumper_asm.S
setarch -R ./test_static_malloc $W/sm.ckpt
$GEM5_BIN --outdir=$W/brk_static --debug-flags=SyscallVerbose --debug-file=sys.trace \
    $R/gem5_configs/x86_st_timing.py --cmd=$R/build/loader \
    --options="$W/sm.ckpt" --cpu=atomic --maxinsts=2000000000
grep -E "brk" $W/brk_static/sys.trace | head
```
Esperado:
- `Loader: .../loader`.
- Un `brk` con argumento = final del `[heap]`, emitido **desde el trampolin**
  justo antes del `m5_exit` (reduce el break; desmapea el propio loader, por
  eso se hace desde la pagina scratch).
- Los `brk` del ROI crecen desde ahi y el programa imprime `STATIC MALLOC OK`.
- Sin el arreglo, gem5 trata ese crecimiento como una reduccion (`brk`
  devuelve lo pedido pero no mapea nada) y el ROI muere al tocar la memoria
  nueva del heap.

En nativo este caso necesita `CAP_SYS_RESOURCE` (`sudo`): Linux no deja al
loader bajar el break por debajo de su `start_brk` salvo con
`prctl(PR_SET_MM)`. `test/run_native_tests.sh` lo detecta y, sin el permiso,
prueba el mismo programa enlazado por encima del loader.

Coste: con `loader_pie` la ampliacion es de ~1 GiB y en gem5 tarda poco. Si el
loader imprime `target heap far above/below the loader break`, se esta usando
el loader equivocado para ese checkpoint.

## 4. vDSO / reloj (bug 11)

```bash
dump test_vdso 300000000
st $W/test_vdso.ckpt 20000000000
```
Esperado: `[loader] [vdso] entry points redirected to syscalls: 0xb` (o similar,
> 0) y `CLOCK OK`. En `sys.trace` aparecen syscalls `clock_gettime` y
`gettimeofday` durante el ROI (antes no: se ejecutaba el codigo del vDSO del
host sobre una `[vvar]` congelada, y el programa veia el reloj parado:
`CLOCK STUCK`, o valores sin sentido).

## 5. FDs y remapeo (bug 9)

```bash
sbatch $R/test_fd_slurm.sh     # o ejecutarlo directamente
```
Esperado: `OK: prueba de FDs en gem5` (`Restored from dump!`, lectura de
`67890` desde el fichero movido gracias al remapeo `OLD=NEW`, y `output.txt`
no recreado).

stdin redirigido (p.ej. `503.bwaves_r`): generar el checkpoint con
`./bin < fichero_entrada` y comprobar en el log del loader
`FD 0x0 ... path: /ruta/al/fichero` sin `WARNING`, y que el ROI sigue leyendo.

## 6. SMT-N (bug 10)

```bash
$R/launch_scripts/run_mixed.sh smt2_check 1000000 timing $W/t.ckpt $W/test_signal_malloc.ckpt
```
Esperado:
- Cada checkpoint con su loader (`t.ckpt -> loader`, `test_signal_malloc.ckpt -> loader_pie`).
- `[loader] SMT barrier passed` en los dos procesos.
- En las lineas `[loader k/2] listo ... insts=[a, b]`, la diferencia de
  instrucciones de cada hilo entre el primer y el segundo `m5_exit` es pequena
  (miles, no millones): es el ROI que un hilo ejecuta en la CPU simple
  mientras el otro llega. Sin la barrera era todo lo que tardara el otro
  loader en restaurar.

## 7. Checkpoints truncados (bug 6)

```bash
head -c 3000000 $W/test_signal_malloc.ckpt > $W/trunc.ckpt
python3 $R/tools/ckpt_inspect.py $W/trunc.ckpt | grep '!!'
st $W/trunc.ckpt 1000
```
Esperado: `ckpt_inspect` avisa `checkpoint truncado` y el loader aborta con
`Corrupt or truncated checkpoint` en lugar de restaurar basura. Al regenerar
con `regenerate_ckpt_noavx.sh`, nunca queda un `dump_*.ckpt` a medias: o esta
completo o no existe (`dump_*.ckpt.tmp` se borra).

## 8. SPEC de extremo a extremo

```bash
$R/launch_scripts/regenerate_ckpt_noavx.sh all        # regenerar: formato v2
python3 $R/tools/ckpt_inspect.py $CKPT_DIR/dump_mcf_r_noavx.ckpt | head -4
$R/launch_scripts/run_st_timing.sh $CKPT_DIR/dump_mcf_r_noavx.ckpt 10000000 atomic
$R/launch_scripts/run_10M_suite.sh
```
Esperado: `ver=2`, `loader recomendado: build/loader_pie`, ROI completo sin
`FATAL` y estadisticas comparables a las de antes (los checkpoints v1 anteriores
se rechazan: `Version mismatch`, hay que regenerarlos).

"""
x86_mixed_2core.py - Extension de x86_mixed.py a 2 nucleos fisicos, cada uno
en SMT-2 (2 hilos logicos), 4 hilos en total.

Mismo patron de 2 fases que x86_mixed.py (carga en CPU simple + m5_exit,
switchCpus a DerivO3CPU para el ROI), mas una diferencia clave: cada
aplicacion puede tener un ritmo de ejecucion muy distinto (mismo numero de
instrucciones de ROI, duraciones de reloj nativas muy distintas), asi que
scheduleInstStop() por si solo detendria TODA la simulacion en cuanto el
primer hilo (de cualquiera de los 2 nucleos) alcance su objetivo, truncando
la ROI del resto (bug detectado y documentado en la Seccion "Resultados
obtenidos" del TFM para el caso de 2 hilos).

Aqui, en su lugar, se captura cada evento scheduleInstStop individualmente y
se suspende (system.o3_N.suspendContext(tid)) solo ESE hilo -- deja de
competir por recursos de despacho, pero el resto de hilos activos (en el
mismo nucleo o en el otro) siguen ejecutando con normalidad -- hasta que los
4 han alcanzado su propio maxinsts. Cada hilo obtiene asi su ROI completa de
maxinsts instrucciones, bajo el nivel de contencion real del escenario
(decreciente segun otros hilos van terminando y suspendiendose).

Requiere suspendContext/activateContext expuestos a Python en BaseCPU.py
(cxx_exports) -- no vienen expuestos de fabrica en gem5; parcheado en este
arbol.

Como en x86_mixed.py: el loader de cada checkpoint se elige solo
(build/loader o build/loader_pie, ver rmc_common.py), cada proceso arranca en
el cwd de su checkpoint (con los remapeos de --loader-opts) y, en la carga
concurrente, los loaders de todos los hilos se sincronizan con una barrera
antes de su m5_exit para que ningun ROI empiece en la CPU simple mientras
otros restauran. Con --seq-load no hay barrera (los hilos suspendidos nunca
llegarian a ella).

Con --restore direct (por defecto si el gem5 la soporta) no hay fase de
carga: gem5 instala los 4 checkpoints en Process.initState() y las O3 son las
CPUs activas desde el tick 0, con los 4 ROI empezando a la vez. Sin loaders
no hay barrera ni restauraciones concurrentes (--seq-load no aplica).

Uso:
  gem5.opt --outdir=DIR x86_mixed_2core.py --loader LOADER \
      --ckpts0 A.ckpt B.ckpt --ckpts1 C.ckpt D.ckpt \
      [--restore auto|direct|loader] \
      [--load-cpu timing|atomic] [--maxinsts 10000000] [--pmu] \
      [--loader-opts "OLD=NEW ..."]
"""
import argparse
import os
import re
import sys
import m5
from m5.objects import *

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from rmc_common import RESTORE_MODES, make_process, resolve_restore

parser = argparse.ArgumentParser(description="RMC: 2 nucleos SMT-2, carga simple + ROI en DerivO3CPU")
parser.add_argument("--loader",   type=str, required=True, help="Binario loader (no PIE)")
parser.add_argument("--loader-pie", type=str, default=None,
                    help="Loader para checkpoints PIE (por defecto <loader>_pie si existe)")
parser.add_argument("--loader-opts", type=str, default="",
                    help="Argumentos extra para todos los loaders (remapeos OLD=NEW)")
parser.add_argument("--ckpts0",   type=str, nargs="+", required=True, help="Checkpoints del nucleo 0")
parser.add_argument("--ckpts1",   type=str, nargs="+", required=True, help="Checkpoints del nucleo 1")
parser.add_argument("--maxinsts", type=int, default=10_000_000,
                    help="Instrucciones de ROI por hilo (cada hilo alcanza SU propio objetivo)")
parser.add_argument("--load-cpu", type=str, default="timing", choices=["timing", "atomic"])
parser.add_argument("--restore", type=str, default="auto", choices=RESTORE_MODES,
                    help="direct: gem5 instala los checkpoints sin simular nada (cero ciclos); "
                         "loader: se simulan los loaders; auto: direct si este gem5 lo soporta")
parser.add_argument("--maxinsts-list", type=str, default=None,
                    help="Objetivo de instrucciones POR HILO, separado por comas y en el orden "
                         "ckpts0...,ckpts1... Ajustarlo al IPC de cada aplicacion hace que todas "
                         "terminen a la vez y la ROI entera transcurra con contencion plena.")
parser.add_argument("--calib-ticks", type=int, default=0,
                    help="Modo calibracion: simular N ticks con los 4 hilos activos y reportar "
                         "cuantas instrucciones completa cada uno (da su IPC bajo contencion real).")
parser.add_argument("--no-caches", action="store_true")
parser.add_argument("--seq-load", action="store_true",
                    help="Restaurar los checkpoints de uno en uno (evita la corrupcion por restauracion concurrente)")
parser.add_argument("--no-switch", action="store_true",
                    help="Diagnostico: ejecutar la ROI en la CPU simple, sin conmutar a O3")
parser.add_argument("--mem",      type=str, default="8GiB")
parser.add_argument("--clock",    type=str, default="2GHz")
parser.add_argument("--pmu", action="store_true",
                    help="Instrumentacion PMU del GAP en ambos nucleos (CPU_0_* y CPU_1_*).")
args = parser.parse_args()

NT0, NT1 = len(args.ckpts0), len(args.ckpts1)
RESTORE = resolve_restore(args.restore)
DIRECT = RESTORE == "direct"
# Restauracion directa: las O3 son las CPUs activas desde el tick 0 (salvo
# --no-switch, que deja el ROI en las CPUs simples para diagnostico).
O3_ACTIVE = DIRECT and not args.no_switch

# Loader, cwd y argumentos de cada checkpoint (rutas absolutas: cada proceso
# arranca en el cwd de su checkpoint)
REMAPS = args.loader_opts.split()
LOADER_EXTRA = []
if not DIRECT and not args.seq_load and NT0 + NT1 > 1:
    barrier = os.path.join(os.path.abspath(m5.options.outdir), "rmc_barrier")
    open(barrier, "w").close()          # vacio: cada loader anade un byte
    LOADER_EXTRA.append(f"--barrier={barrier}:{NT0 + NT1}")
args.ckpts0 = [os.path.abspath(ck) for ck in args.ckpts0]
args.ckpts1 = [os.path.abspath(ck) for ck in args.ckpts1]

system = System()
# Siempre True: es lo que usa el x86_mixed.py validado. Con 2 CPUs y 1 hilo
# cada una quedaba en False, que es una de las diferencias de configuracion
# frente al caso que funciona.
system.multi_thread = True
system.clk_domain   = SrcClockDomain(clock=args.clock, voltage_domain=VoltageDomain())
system.mem_mode     = "timing"
system.mem_ranges   = [AddrRange(args.mem)]
system.membus       = SystemXBar()
system.mem_ctrl            = MemCtrl()
system.mem_ctrl.dram       = DDR4_2400_8x8()
system.mem_ctrl.dram.range = system.mem_ranges[0]
system.mem_ctrl.port       = system.membus.mem_side_ports
system.system_port         = system.membus.cpu_side_ports


def build_o3(idx, nt, switched_out=True):
    cpu_o3 = DerivO3CPU(cpu_id=idx, numThreads=nt, switched_out=switched_out)
    cpu_o3.max_insts_any_thread = 0
    if args.pmu:
        cpu_o3.pmuDispatchActive = True
        cpu_o3.pmuIssueActive    = True
        cpu_o3.pmuInitCycle      = 0
    return cpu_o3


def build_core(idx, nt, ckpts):
    """Crea la CPU activa de un nucleo, con su propia jerarquia privada
    L1I/L1D/L2: la CPU simple de carga o, en restauracion directa, la propia
    O3. Las DerivO3CPU de conmutacion se crean DESPUES, todas juntas: ver el
    bloque posterior a las llamadas a build_core()."""
    if O3_ACTIVE:
        cpu = build_o3(idx, nt, switched_out=False)
    else:
        cpu = (TimingSimpleCPU(cpu_id=idx, numThreads=nt) if args.load_cpu == "timing"
                      else AtomicSimpleCPU(cpu_id=idx, numThreads=nt))
        cpu.max_insts_any_thread = 0

    if not args.no_caches:
        class L1ICache(Cache):
            size = "32kB"; assoc = 8
            tag_latency = 1; data_latency = 1; response_latency = 1
            mshrs = 4; tgts_per_mshr = 20

        class L1DCache(Cache):
            size = "32kB"; assoc = 8
            tag_latency = 2; data_latency = 2; response_latency = 2
            mshrs = 16; tgts_per_mshr = 20

        class L2Cache(Cache):
            size = "256kB"; assoc = 8
            tag_latency = 10; data_latency = 10; response_latency = 10
            mshrs = 20; tgts_per_mshr = 12

        icache, dcache, l2cache = L1ICache(), L1DCache(), L2Cache()
        l2bus = L2XBar()
        cpu.icache_port = icache.cpu_side
        cpu.dcache_port = dcache.cpu_side
        icache.mem_side  = l2bus.cpu_side_ports
        dcache.mem_side  = l2bus.cpu_side_ports
        l2cache.cpu_side = l2bus.mem_side_ports
        l2cache.mem_side = system.membus.cpu_side_ports
    else:
        cpu.icache_port = system.membus.cpu_side_ports
        cpu.dcache_port = system.membus.cpu_side_ports
        icache = dcache = l2cache = l2bus = None

    cpu.createInterruptController()
    for j in range(len(cpu.interrupts)):
        cpu.interrupts[j].pio           = system.membus.mem_side_ports
        cpu.interrupts[j].int_requestor = system.membus.cpu_side_ports
        cpu.interrupts[j].int_responder = system.membus.mem_side_ports

    # Mismo GLIBC_TUNABLES usado al generar los checkpoints en altek (desactiva
    # AVX/AVX2/BMI2 en el resolvedor IFUNC de glibc). Si el proceso restaurado
    # resuelve por primera vez una funcion de glibc durante la ROI (resolucion
    # perezosa) sin este tunable en su entorno, puede elegir una variante
    # AVX2/BMI2 que gem5 no implementa -> panic "Unrecognized/invalid
    # instruction". Se fuerza aqui, no basta con haberlo puesto solo al volcar.
    # (Solo con loader: en restauracion directa el entorno del proceso es el
    # del checkpoint, que gen_ckpt.sh ya genera con este tunable.)
    NOAVX_TUNABLES = ("glibc.cpu.hwcaps=-SSE4_2,-SSE4_1,-SSSE3,-AVX,-AVX2,"
                       "-AVX512F,-AVX_Usable,-AVX2_Usable,-AVX512F_Usable,"
                       "-AVX_Fast_Unaligned_Load")
    env_dict = dict(os.environ)
    env_dict["GLIBC_TUNABLES"] = NOAVX_TUNABLES
    env_list = [f"{k}={v}" for k, v in env_dict.items()]
    procs = []
    for i, ck in enumerate(ckpts):
        proc, ld, cwd = make_process(ck, RESTORE, args.loader, args.loader_pie, REMAPS,
                                     LOADER_EXTRA, pid=100 + idx * 10 + i, env=env_list)
        via = "directa" if DIRECT else os.path.basename(ld)
        print(f"  nucleo{idx} hilo{i}: {os.path.basename(ck)} -> {via}  cwd={cwd}", flush=True)
        procs.append(proc)

    cpu.workload = procs

    return cpu, (icache, dcache, l2cache, l2bus)


# ORDEN DE REGISTRO CRITICO: gem5 asigna los context id a cada contexto de hilo
# en el orden en que las CPUs se cuelgan del System, y en SE mode cada Process
# queda ligado a esos ids. El patron estandar (configs/common/Simulation.py)
# registra PRIMERO todas las CPUs de ejecucion y DESPUES todas las de
# conmutacion. Registrarlas intercaladas (cpu0, o3_0, cpu1, o3_1) desordena esa
# correspondencia y, tras takeOverFrom(), un nucleo puede acabar ejecutando con
# el espacio de direcciones del proceso equivocado -> busca instrucciones en
# memoria ajena -> panic "Unrecognized/invalid instruction" nada mas entrar al
# ROI. Por eso: primero cpu0 y cpu1, luego o3_0 y o3_1.
if O3_ACTIVE:
    # Restauracion directa: las O3 (mismos nombres, mismas stats) son las
    # unicas CPUs, sin CPUs de carga ni conmutacion.
    system.o3_0, caches0 = build_core(0, NT0, args.ckpts0)
    system.o3_1, caches1 = build_core(1, NT1, args.ckpts1)
else:
    system.cpu0, caches0 = build_core(0, NT0, args.ckpts0)
    system.cpu1, caches1 = build_core(1, NT1, args.ckpts1)
if not args.no_caches:
    system.icache0, system.dcache0, system.l2cache0, system.l2bus0 = caches0
    system.icache1, system.dcache1, system.l2cache1, system.l2bus1 = caches1

if not O3_ACTIVE:
    system.o3_0 = build_o3(0, NT0)
    system.o3_1 = build_o3(1, NT1)

# Solo elige ISA/SO: en directo el ejecutable (el loader) no se carga
system.workload = SEWorkload.init_compatible(args.loader)

if O3_ACTIVE:
    system.o3_0.createThreads()
    system.o3_1.createThreads()
else:
    # Y dentro de cada par, el orden de x86_mixed.py (1 nucleo), ya validado:
    # createThreads() de la CPU simple primero -- es quien crea los objetos ISA por
    # hilo -- y solo despues se comparten esos objetos ya creados con la CPU O3.
    for cpu_simple, cpu_o3 in ((system.cpu0, system.o3_0), (system.cpu1, system.o3_1)):
        cpu_simple.createThreads()
        cpu_o3.isa      = cpu_simple.isa
        cpu_o3.workload = cpu_simple.workload
        cpu_o3.createThreads()

root = Root(full_system=False, system=system)
m5.instantiate()

CORES = [(0, None if O3_ACTIVE else system.cpu0, system.o3_0, NT0, args.ckpts0),
         (1, None if O3_ACTIVE else system.cpu1, system.o3_1, NT1, args.ckpts1)]
NT_TOTAL = NT0 + NT1

if DIRECT:
    print(f"**** {NT_TOTAL} checkpoints instalados en initState: 0 ciclos de carga ****",
          flush=True)
else:
    print(f"**** FASE 1: {NT_TOTAL} loader(es) en {args.load_cpu} (2 nucleos) ****", flush=True)

# Lista plana de (cpu_simple, tid) de todos los hilos, en orden.
ALL_THREADS = [(cpu_simple, t)
               for _, cpu_simple, _, nt, _ in CORES
               for t in range(nt)]

if DIRECT:
    pass
elif args.seq_load:
    # CARGA SECUENCIAL. Restaurar dos checkpoints CONCURRENTEMENTE corrompe el
    # estado del proceso restaurado (la aplicacion acaba abortando con ud2 nada
    # mas entrar a su ROI). Se reproduce siempre que las dos restauraciones se
    # solapan -- dos hilos del mismo checkpoint en un nucleo, o dos nucleos en
    # paralelo -- y NO ocurre cuando por casualidad se escalonan (p.ej. mcf_r +
    # perlbench_r en un nucleo, cuyos loaders tardan tiempos muy distintos).
    # Por eso aqui se restaura de uno en uno: solo un hilo activo a la vez,
    # suspendiendo el resto, y al final se reactivan todos.
    # Nota: no se puede suspender el hilo que acaba de terminar su loader --
    # TimingSimpleCPU::suspendContext exige _status == Running y tras el evento
    # m5_exit no lo esta (aborta con assert). Basta con arrancar suspendidos
    # todos menos el primero e ir activandolos de uno en uno: asi la
    # restauracion de cada checkpoint no se solapa con la de ningun otro.
    for cpu_simple, tid in ALL_THREADS[1:]:
        cpu_simple.suspendContext(tid)

    for i, (cpu_simple, tid) in enumerate(ALL_THREADS):
        if i > 0:
            cpu_simple.activateContext(tid)
        ev = m5.simulate()
        cause = ev.getCause()
        if cause != "m5_exit instruction encountered":
            print(f"!!! Evento inesperado durante la carga: '{cause}' @ {m5.curTick()}", flush=True)
            raise SystemExit(1)
        print(f"  [loader {i + 1}/{NT_TOTAL}] listo en tick {m5.curTick()}", flush=True)

    print("**** Todos los checkpoints restaurados secuencialmente ****", flush=True)
else:
    done = 0
    while done < NT_TOTAL:
        ev    = m5.simulate()
        cause = ev.getCause()
        if cause == "m5_exit instruction encountered":
            done += 1
            print(f"  [loader {done}/{NT_TOTAL}] listo en tick {m5.curTick()}", flush=True)
        else:
            print(f"!!! Evento inesperado durante la carga: '{cause}' @ {m5.curTick()}", flush=True)
            raise SystemExit(1)

for core_idx, cpu_simple, cpu_o3, nt, ckpts in CORES:
    if DIRECT:
        break
    loaded = [cpu_simple.getCurrentInstCount(t) for t in range(nt)]
    print(f"**** Carga completa nucleo {core_idx}. Instrucciones por hilo: {loaded} ****", flush=True)

if args.no_switch:
    # Diagnostico: ejecutar la ROI en la propia CPU simple, sin conmutar. Sirve
    # para separar "el montaje de 2 nucleos esta mal" de "el fallo esta en
    # m5.switchCpus() con dos nucleos".
    print("**** SIN CONMUTAR: la ROI se ejecuta en la CPU simple ****", flush=True)
    ROI_CPUS = [(idx, cpu_simple, nt, ckpts) for idx, cpu_simple, _, nt, ckpts in CORES]
elif O3_ACTIVE:
    print("**** ROI en DerivO3CPU desde el tick 0 (restauracion directa) ****", flush=True)
    ROI_CPUS = [(idx, cpu_o3, nt, ckpts) for idx, _, cpu_o3, nt, ckpts in CORES]
else:
    print("**** Cambiando ambos nucleos a DerivO3CPU"
          f"{'' if args.no_caches else ' (con caches L1/L2 privadas)'} ****", flush=True)
    m5.switchCpus(system, [(system.cpu0, system.o3_0), (system.cpu1, system.o3_1)])
    ROI_CPUS = [(idx, cpu_o3, nt, ckpts) for idx, _, cpu_o3, nt, ckpts in CORES]
m5.stats.reset()

if args.calib_ticks:
    print(f"**** CALIBRACION: {args.calib_ticks} ticks con los {NT_TOTAL} hilos activos ****", flush=True)
    m5.simulate(args.calib_ticks)
    print("**** Instrucciones completadas por hilo (contencion plena) ****", flush=True)
    for core_idx, roi_cpu, nt, ckpts in ROI_CPUS:
        for t in range(nt):
            n = roi_cpu.getCurrentInstCount(t)
            print(f"  nucleo{core_idx} hilo{t} ({os.path.basename(ckpts[t])}): {n}", flush=True)
    raise SystemExit(0)

TARGETS = ([int(x) for x in args.maxinsts_list.split(",")]
           if args.maxinsts_list else [args.maxinsts] * NT_TOTAL)
if len(TARGETS) != NT_TOTAL:
    raise SystemExit(f"--maxinsts-list necesita {NT_TOTAL} valores, dados {len(TARGETS)}")

k = 0
for core_idx, roi_cpu, nt, ckpts in ROI_CPUS:
    for t in range(nt):
        roi_cpu.scheduleInstStop(
            t, TARGETS[k],
            f"ROI core{core_idx} hilo{t} alcanzo {TARGETS[k]} instrucciones")
        k += 1

print(f"**** FASE 2: ROI en {'CPU simple' if args.no_switch else 'O3'}, "
      f"{args.maxinsts} instrucciones por hilo, "
      f"{NT_TOTAL} hilos en 2 nucleos ****", flush=True)

CAUSE_RE = re.compile(r"^ROI core(\d+) hilo(\d+) alcanzo")
remaining = NT_TOTAL
while remaining > 0:
    ev    = m5.simulate()
    cause = ev.getCause()
    m = CAUSE_RE.match(cause)
    if not m:
        print(f"!!! Evento inesperado durante el ROI: '{cause}' @ tick {m5.curTick()}", flush=True)
        raise SystemExit(1)
    core_idx, tid = int(m.group(1)), int(m.group(2))
    if args.no_switch:
        cpu_o3 = system.cpu0 if core_idx == 0 else system.cpu1
    else:
        cpu_o3 = system.o3_0 if core_idx == 0 else system.o3_1
    insts_now = cpu_o3.getCurrentInstCount(tid)
    cpu_o3.suspendContext(tid)
    remaining -= 1
    print(f"  -> {cause} (tick {m5.curTick()}, {insts_now} insts) -- hilo suspendido, "
          f"quedan {remaining} activos", flush=True)

print(f"**** ROI terminado: los {NT_TOTAL} hilos alcanzaron su objetivo. tick final {m5.curTick()} ****",
      flush=True)
for core_idx, _, cpu_o3, nt, ckpts in CORES:
    for t in range(nt):
        insts = cpu_o3.getCurrentInstCount(t)
        print(f"     nucleo{core_idx} hilo{t} ({os.path.basename(ckpts[t])}): "
              f"{insts} instrucciones de ROI", flush=True)

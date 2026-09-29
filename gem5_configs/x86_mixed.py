"""
x86_mixed.py - Restauracion RMC con el ROI en O3.

Restauracion directa (--restore direct, por defecto si el gem5 la soporta):
  gem5 instala cada checkpoint en Process.initState(), sin simular nada: la
  DerivO3CPU arranca en el tick 0 ya en el ROI. Con --warmup N, antes del ROI
  se ejecutan N instrucciones en la CPU simple (calientan caches y TLB) y se
  conmuta a O3 como en el modo loader.

Restauracion por loader (--restore loader):
  Fase 1 (carga) : TimingSimpleCPU (o AtomicSimpleCPU) ejecuta el loader, que
                   restaura las regiones y lanza m5_exit(0) antes de saltar al ROI.
  Fase 2 (ROI)   : m5.switchCpus() traspasa el estado a DerivO3CPU, que hereda
                   la jerarquia L1/L2 por takeOverFrom(). Stats reseteadas.

Soporta 1 checkpoint (single-thread) o N checkpoints en SMT-N sobre un mismo
nucleo (multiprogramado: procesos independientes compartiendo el core).

CLAVE: la CPU switched-out NO debe tener controlador de interrupciones ni
puertos conectados. Crearselos (p.ej. colgados de un dummy bus) hace que gem5
aborte en el tick 0 con:
    Interrupts::getAddrRanges(): Assertion `tc' failed
Se sigue el patron de configs/common/Simulation.py: a la CPU switched-out solo
se le asignan system, clk_domain, workload e isa (compartida), y createThreads().

En SMT-N los loaders se sincronizan con una barrera (--barrier del loader)
antes de su m5_exit: sin ella, el primer loader en terminar ejecutaria su
ROI en la CPU simple mientras los demas siguen restaurando, y los ROI no
empezarian a la vez.

El loader de cada checkpoint se elige solo (build/loader o build/loader_pie,
ver rmc_common.py). En restauracion directa no hay loader ni barrera: todos
los hilos empiezan su ROI a la vez, en el tick 0.

Uso:
  gem5.opt --outdir=DIR x86_mixed.py --loader LOADER --ckpts A.ckpt [B.ckpt] \
           [--restore auto|direct|loader] [--warmup N] \
           [--load-cpu timing|atomic] [--maxinsts 1000000] [--no-caches] \
           [--loader-opts "OLD=NEW ..."]
"""
import argparse
import os
import sys
import m5
from m5.objects import *

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from rmc_common import RESTORE_MODES, make_process, resolve_restore

parser = argparse.ArgumentParser(description="RMC: carga en CPU simple, ROI en DerivO3CPU")
parser.add_argument("--loader",   type=str, required=True, help="Binario loader (no PIE)")
parser.add_argument("--loader-pie", type=str, default=None,
                    help="Loader para checkpoints PIE (por defecto <loader>_pie si existe)")
parser.add_argument("--loader-opts", type=str, default="",
                    help="Argumentos extra para todos los loaders (remapeos OLD=NEW)")
parser.add_argument("--ckpts",    type=str, nargs="+", required=True,
                    help="1 checkpoint (ST) o N checkpoints (SMT-N sobre un core)")
parser.add_argument("--maxinsts", type=int, default=1000000,
                    help="Instrucciones de ROI (por hilo; para el primero que llegue)")
parser.add_argument("--restore", type=str, default="auto", choices=RESTORE_MODES,
                    help="direct: gem5 instala el checkpoint sin simular nada (cero ciclos); "
                         "loader: se simula el loader; auto: direct si este gem5 lo soporta")
parser.add_argument("--warmup", type=int, default=0,
                    help="Solo --restore direct: instrucciones en la CPU simple antes de "
                         "conmutar a O3 (calentar caches). 0 = O3 desde el tick 0")
parser.add_argument("--load-cpu", type=str, default="timing", choices=["timing", "atomic"],
                    help="CPU de la fase de carga (o del calentamiento)")
parser.add_argument("--no-caches", action="store_true", help="Desactivar L1/L2")
parser.add_argument("--mem",      type=str, default="8GiB")
parser.add_argument("--clock",    type=str, default="2GHz")
parser.add_argument("--trace-roi", action="store_true", help="Flag Exec solo en el ROI")
parser.add_argument("--pmu", action="store_true",
                    help="Instrumentacion PMU del GAP: vuelca CPU_*_THD_*_{DISPATCH_STALLS,"
                         "ISSUE_STALLS,FU_DISTRIBUTION}.csv en el CWD de gem5. Solo mide el "
                         "ROI, porque la CPU O3 no tiene ciclos hasta el switch.")
args = parser.parse_args()

NT = len(args.ckpts)
RESTORE = resolve_restore(args.restore)
if RESTORE == "loader" and args.warmup:
    raise SystemExit("--warmup solo tiene sentido con --restore direct")
# Con loader siempre hay CPU simple + conmutacion; en directo, solo si se
# pide calentamiento. Si no, la O3 es la unica CPU y arranca ya en el ROI.
SWITCH = RESTORE == "loader" or args.warmup > 0

# -- Sistema ----------------------------------------------------------------
system = System()
system.multi_thread = NT > 1
system.clk_domain   = SrcClockDomain(clock=args.clock, voltage_domain=VoltageDomain())
# El modo de memoria es el de la CPU que arranca: atomic solo si la carga (o
# el calentamiento) va en AtomicSimpleCPU; switchCpus() pasa a timing para O3.
system.mem_mode     = "atomic" if SWITCH and args.load_cpu == "atomic" else "timing"
system.mem_ranges   = [AddrRange(args.mem)]

if SWITCH:
    # CPU activa durante la carga (o el calentamiento)
    system.cpu = (TimingSimpleCPU(cpu_id=0, numThreads=NT) if args.load_cpu == "timing"
                  else AtomicSimpleCPU(cpu_id=0, numThreads=NT))
    system.cpu.max_insts_any_thread = 0

    # CPU de ROI: switched_out. SIN interrupts y SIN puertos (los hereda al switch).
    # OJO: no asignar system.o3.system ni .clk_domain a mano. Como system.o3 es
    # hijo de system, los proxies Parent.any de esos parametros ya los resuelven;
    # asignarlos reparenta `system` bajo `system.o3` y crea un ciclo en el arbol de
    # SimObjects -> RecursionError en SimObject.path() al construir el siguiente
    # SimObject. (Simulation.py si los asigna porque alli las switch_cpus se crean
    # sueltas, fuera del arbol.)
    system.o3 = DerivO3CPU(cpu_id=0, numThreads=NT, switched_out=True)
    active = system.cpu
else:
    # Restauracion directa sin calentamiento: la O3 es la unica CPU y la
    # activa. Se sigue llamando system.o3 para que las stats (system.o3.*)
    # sean las mismas en ambos modos (parse_roi_stats.py).
    system.o3 = DerivO3CPU(cpu_id=0, numThreads=NT)
    active = system.o3
system.o3.max_insts_any_thread = 0
if args.pmu:
    system.o3.pmuDispatchActive = True
    system.o3.pmuIssueActive    = True
    system.o3.pmuInitCycle      = 0

system.membus = SystemXBar()

# -- Jerarquia de cache (colgada de la CPU activa; el switch la traspasa) ----
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

    system.icache  = L1ICache()
    system.dcache  = L1DCache()
    system.l2bus   = L2XBar()
    system.l2cache = L2Cache()

    active.icache_port = system.icache.cpu_side
    active.dcache_port = system.dcache.cpu_side
    system.icache.mem_side  = system.l2bus.cpu_side_ports
    system.dcache.mem_side  = system.l2bus.cpu_side_ports
    system.l2cache.cpu_side = system.l2bus.mem_side_ports
    system.l2cache.mem_side = system.membus.cpu_side_ports
else:
    active.icache_port = system.membus.cpu_side_ports
    active.dcache_port = system.membus.cpu_side_ports

system.system_port = system.membus.cpu_side_ports

# Solo la CPU activa lleva controlador de interrupciones.
active.createInterruptController()
for j in range(len(active.interrupts)):
    active.interrupts[j].pio           = system.membus.mem_side_ports
    active.interrupts[j].int_requestor = system.membus.cpu_side_ports
    active.interrupts[j].int_responder = system.membus.mem_side_ports

system.mem_ctrl            = MemCtrl()
system.mem_ctrl.dram       = DDR4_2400_8x8()
system.mem_ctrl.dram.range = system.mem_ranges[0]
system.mem_ctrl.port       = system.membus.mem_side_ports

# -- Cargas de trabajo: un proceso por hilo, cada uno con su checkpoint -----
env_list = [f"{k}={v}" for k, v in os.environ.items()]
remaps = args.loader_opts.split()
loader_args = []
if RESTORE == "loader" and NT > 1:
    barrier = os.path.join(os.path.abspath(m5.options.outdir), "rmc_barrier")
    open(barrier, "w").close()          # vacio: cada loader anade un byte
    loader_args.append(f"--barrier={barrier}:{NT}")
# Rutas absolutas: cada proceso arranca en el cwd de su checkpoint
ckpts = [os.path.abspath(ck) for ck in args.ckpts]
print(f"**** Restauracion: {RESTORE} ****", flush=True)
procs, exes = [], []
for i, ck in enumerate(ckpts):
    proc, exe, cwd = make_process(ck, RESTORE, args.loader, args.loader_pie, remaps,
                                  loader_args, pid=100 + i, env=env_list)
    procs.append(proc)
    exes.append(exe)
    via = "directa" if RESTORE == "direct" else os.path.basename(exe)
    print(f"  {os.path.basename(ck)} -> {via}  cwd={cwd}", flush=True)

system.workload     = SEWorkload.init_compatible(exes[0])
active.workload = procs
active.createThreads()

if SWITCH:
    # La ISA se COMPARTE con la CPU switched-out (igual que Simulation.py), para
    # que el estado arquitectonico (incluido fs_base) sobreviva al traspaso.
    system.o3.isa      = system.cpu.isa
    system.o3.workload = system.cpu.workload
    system.o3.createThreads()

root = Root(full_system=False, system=system)
m5.instantiate()

# -- Fase 1: carga (loader) o calentamiento (directa) -----------------------
if RESTORE == "loader":
    print(f"**** FASE 1: {NT} loader(es) en {args.load_cpu} ****", flush=True)
    done = 0
    while done < NT:
        ev    = m5.simulate()
        cause = ev.getCause()
        if cause == "m5_exit instruction encountered":
            done += 1
            # Instrucciones por hilo en cada m5_exit: tras la barrera, lo que un
            # hilo avance entre el primer y el ultimo m5_exit es ROI ejecutado en
            # la CPU simple (debe ser despreciable frente a --maxinsts).
            counts = [active.getCurrentInstCount(t) for t in range(NT)]
            print(f"  [loader {done}/{NT}] listo en tick {m5.curTick()}  insts={counts}",
                  flush=True)
        else:
            print(f"!!! Evento inesperado durante la carga: '{cause}' @ {m5.curTick()}", flush=True)
            print(f"Exited @ tick {m5.curTick()} because {cause}")
            raise SystemExit(1)
    load_insts = [active.getCurrentInstCount(t) for t in range(NT)]
    print(f"**** Carga completa. Instrucciones por hilo: {load_insts} ****", flush=True)
elif args.warmup:
    print(f"**** FASE 1: calentamiento de {args.warmup} instrucciones en {args.load_cpu} ****",
          flush=True)
    for t in range(NT):
        active.scheduleInstStop(t, args.warmup, f"calentamiento: hilo {t}")
    ev = m5.simulate()
    if not ev.getCause().startswith("calentamiento"):
        print(f"!!! Evento inesperado durante el calentamiento: '{ev.getCause()}' "
              f"@ {m5.curTick()}", flush=True)
        print(f"Exited @ tick {m5.curTick()} because {ev.getCause()}")
        raise SystemExit(1)
    warm = [active.getCurrentInstCount(t) for t in range(NT)]
    print(f"**** Calentamiento completo. Instrucciones por hilo: {warm} ****", flush=True)
else:
    print("**** Checkpoint(s) instalados en initState: 0 ciclos de carga ****", flush=True)

# -- Cambio de CPU ----------------------------------------------------------
if SWITCH:
    print("**** Cambiando a DerivO3CPU"
          f"{'' if args.no_caches else ' (con caches L1/L2)'} ****", flush=True)
    m5.switchCpus(system, [(system.cpu, system.o3)])

m5.stats.reset()
if args.trace_roi:
    from m5.debug import flags
    flags["Exec"].enable()

# -- Fase 2: ROI en O3 ------------------------------------------------------
for t in range(NT):
    system.o3.scheduleInstStop(t, args.maxinsts,
                             f"ROI: hilo {t} alcanzo {args.maxinsts} instrucciones")

print(f"**** FASE 2: ROI en O3, {args.maxinsts} instrucciones por hilo ****", flush=True)
ev  = m5.simulate()
roi = [system.o3.getCurrentInstCount(t) for t in range(NT)]

print(f"**** ROI terminado: '{ev.getCause()}' ****", flush=True)
for t in range(NT):
    print(f"     hilo {t} ({os.path.basename(args.ckpts[t])}): "
          f"{roi[t]} instrucciones de ROI", flush=True)
print(f"Exited @ tick {m5.curTick()} because {ev.getCause()}")

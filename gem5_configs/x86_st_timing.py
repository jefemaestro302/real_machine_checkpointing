"""
x86_st_timing.py - Arnes RAPIDO de depuracion para checkpoints RMC.

A diferencia de x86_st.py (que simula TODO el loader en DerivO3CPU y tarda
horas), este script usa una CPU simple para la fase del loader, que es
puro memcpy y no aporta nada microarquitectonico.

Fases:
  1. El loader restaura las regiones y ejecuta m5_exit(0) justo antes de
     saltar al ROI  ->  gem5 sale del bucle de simulacion.
  2. Reseteamos stats y programamos un limite de --maxinsts instrucciones.
  3. Simulamos el ROI y reportamos cuantas instrucciones se ejecutaron.

Uso:
  gem5.opt --outdir=DIR x86_st_timing.py --cmd LOADER --options "CKPT [remaps]" \
           [--cpu timing|atomic] [--caches] [--maxinsts 1000000]
"""
import argparse
import os
import m5
from m5.objects import *

parser = argparse.ArgumentParser(description="Arnes rapido (CPU simple) para restaurar checkpoints RMC")
parser.add_argument("--cmd",      type=str, required=True, help="Binario loader")
parser.add_argument("--options",  type=str, default="",    help="Argumentos del loader (ckpt + remapeos)")
parser.add_argument("--maxinsts", type=int, default=1000000, help="Instrucciones a simular en el ROI")
parser.add_argument("--cpu",      type=str, default="timing", choices=["timing", "atomic"],
                    help="Modelo de CPU (timing = TimingSimpleCPU, atomic = AtomicSimpleCPU)")
parser.add_argument("--caches",   action="store_true", help="Anadir jerarquia L1/L2 (mas lento)")
parser.add_argument("--mem",      type=str, default="8GiB", help="Tamano de memoria fisica simulada")
parser.add_argument("--trace-roi", action="store_true",
                    help="Activar el flag de depuracion Exec SOLO durante el ROI")
args = parser.parse_args()

# -- Sistema ----------------------------------------------------------------
system = System()
system.clk_domain = SrcClockDomain(clock="2GHz", voltage_domain=VoltageDomain())
system.mem_mode   = "timing" if args.cpu == "timing" else "atomic"
system.mem_ranges = [AddrRange(args.mem)]

system.cpu = TimingSimpleCPU() if args.cpu == "timing" else AtomicSimpleCPU()
system.cpu.max_insts_any_thread = 0          # sin limite durante el loader

system.membus = SystemXBar()

if args.caches:
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

    system.cpu.icache = L1ICache()
    system.cpu.dcache = L1DCache()
    system.l2bus      = L2XBar()
    system.l2cache    = L2Cache()

    system.cpu.icache_port  = system.cpu.icache.cpu_side
    system.cpu.dcache_port  = system.cpu.dcache.cpu_side
    system.cpu.icache.mem_side = system.l2bus.cpu_side_ports
    system.cpu.dcache.mem_side = system.l2bus.cpu_side_ports
    system.l2cache.cpu_side    = system.l2bus.mem_side_ports
    system.l2cache.mem_side    = system.membus.cpu_side_ports
else:
    # Sin caches: la CPU habla directamente con el bus de memoria.
    system.cpu.icache_port = system.membus.cpu_side_ports
    system.cpu.dcache_port = system.membus.cpu_side_ports

system.system_port = system.membus.cpu_side_ports

system.cpu.createInterruptController()
system.cpu.interrupts[0].pio           = system.membus.mem_side_ports
system.cpu.interrupts[0].int_requestor = system.membus.cpu_side_ports
system.cpu.interrupts[0].int_responder = system.membus.mem_side_ports

system.mem_ctrl            = MemCtrl()
system.mem_ctrl.dram       = DDR4_2400_8x8()
system.mem_ctrl.dram.range = system.mem_ranges[0]
system.mem_ctrl.port       = system.membus.mem_side_ports

# -- Proceso ----------------------------------------------------------------
env_list = [f"{k}={v}" for k, v in os.environ.items()]
process = Process(pid=100, executable=args.cmd,
                  cmd=[args.cmd] + args.options.split(), env=env_list)
system.workload     = SEWorkload.init_compatible(args.cmd)
system.cpu.workload = process
system.cpu.createThreads()

root = Root(full_system=False, system=system)
m5.instantiate()

# -- Fase 1: loader ---------------------------------------------------------
print(f"**** FASE 1: restaurando checkpoint en {args.cpu} ****", flush=True)
exit_event  = m5.simulate()
cause       = exit_event.getCause()
loader_ins  = system.cpu.getCurrentInstCount(0)
print(f"**** Loader terminado: '{cause}' tras {loader_ins} instrucciones "
      f"(tick {m5.curTick()}) ****", flush=True)

if cause != "m5_exit instruction encountered":
    print("!!! El loader NO llego a la frontera del ROI (falta el m5_exit "
          "o fallo antes). No se simula el ROI.", flush=True)
    print(f"Exited @ tick {m5.curTick()} because {cause}")
    raise SystemExit(1)

# -- Fase 2: ROI ------------------------------------------------------------
m5.stats.reset()
if args.trace_roi:
    # Se activa aqui, no al arrancar, para no trazar los millones de
    # instrucciones del loader.
    from m5.debug import flags
    flags["Exec"].enable()
    print("**** Traza Exec activada para el ROI ****", flush=True)
system.cpu.scheduleInstStop(0, args.maxinsts, f"ROI: {args.maxinsts} instrucciones alcanzadas")

print(f"**** FASE 2: simulando {args.maxinsts} instrucciones de ROI ****", flush=True)
exit_event = m5.simulate()
roi_ins    = system.cpu.getCurrentInstCount(0) - loader_ins

print(f"**** ROI terminado: '{exit_event.getCause()}' ****", flush=True)
print(f"**** Instrucciones de ROI ejecutadas: {roi_ins} / {args.maxinsts} ****", flush=True)
print(f"Exited @ tick {m5.curTick()} because {exit_event.getCause()}")

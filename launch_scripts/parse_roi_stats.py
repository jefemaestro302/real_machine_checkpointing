#!/usr/bin/env python3
"""parse_roi_stats.py - Extrae IPC y MPKI del ROI de uno o varios m5out.

MPKI = fallos de cache por cada 1000 instrucciones comprometidas.
En SMT las caches son compartidas, asi que el MPKI es a nivel de nucleo
(sobre las instrucciones agregadas de todos los hilos); el IPC si se
desglosa por hilo a partir de system.o3.commitStatsN.numInsts.

Uso: parse_roi_stats.py <m5out_dir> [...]   |   --csv para salida CSV
"""
import os, re, sys

def read_stats(path):
    st = {}
    with open(path) as f:
        for line in f:
            m = re.match(r"^(\S+)\s+([\d.eE+-]+)", line)
            if m:
                try:
                    st[m.group(1)] = float(m.group(2))
                except ValueError:
                    pass
    return st

def analyse(d):
    p = os.path.join(d, "stats.txt")
    if not os.path.isfile(p):
        return None
    s = read_stats(p)
    insts  = s.get("simInsts", 0)
    cycles = s.get("system.o3.numCycles", 0)
    if not insts or not cycles:
        return None
    threads = {}
    for k, v in s.items():
        m = re.match(r"^system\.o3\.commitStats(\d+)\.numInsts$", k)
        if m and v > 0:
            threads[int(m.group(1))] = v
    kilo = insts / 1000.0
    return {
        "tag":     os.path.basename(d.rstrip("/")),
        "insts":   insts,
        "cycles":  cycles,
        "ipc":     s.get("system.o3.ipc", insts / cycles),
        "cpi":     s.get("system.o3.cpi", cycles / insts),
        "threads": {t: {"insts": n, "ipc": n / cycles} for t, n in sorted(threads.items())},
        "l1i_mpki": s.get("system.icache.overallMisses::total", 0) / kilo,
        "l1d_mpki": s.get("system.dcache.overallMisses::total", 0) / kilo,
        "l2_mpki":  s.get("system.l2cache.overallMisses::total", 0) / kilo,
        "l1i_mr":   s.get("system.icache.overallMissRate::total", 0),
        "l1d_mr":   s.get("system.dcache.overallMissRate::total", 0),
        "l2_mr":    s.get("system.l2cache.overallMissRate::total", 0),
        "host_s":   s.get("hostSeconds", 0),
        "sim_s":    s.get("simSeconds", 0),
    }

def main(dirs, as_csv):
    rows = [r for r in (analyse(d) for d in dirs) if r]
    if not rows:
        print("Sin stats.txt utilizables"); return 1
    if as_csv:
        print("tag,insts,cycles,ipc,cpi,l1i_mpki,l1d_mpki,l2_mpki,l1i_missrate,l1d_missrate,l2_missrate,host_s")
        for r in rows:
            print(f"{r['tag']},{r['insts']:.0f},{r['cycles']:.0f},{r['ipc']:.4f},{r['cpi']:.4f},"
                  f"{r['l1i_mpki']:.4f},{r['l1d_mpki']:.4f},{r['l2_mpki']:.4f},"
                  f"{r['l1i_mr']:.6f},{r['l1d_mr']:.6f},{r['l2_mr']:.6f},{r['host_s']:.1f}")
        return 0
    hdr = f"{'experimento':<24}{'insts':>12}{'ciclos':>12}{'IPC':>8}{'CPI':>8}" \
          f"{'L1I MPKI':>10}{'L1D MPKI':>10}{'L2 MPKI':>10}{'host s':>9}"
    print(hdr); print("-" * len(hdr))
    for r in rows:
        print(f"{r['tag']:<24}{r['insts']:>12,.0f}{r['cycles']:>12,.0f}"
              f"{r['ipc']:>8.3f}{r['cpi']:>8.3f}"
              f"{r['l1i_mpki']:>10.3f}{r['l1d_mpki']:>10.3f}{r['l2_mpki']:>10.3f}{r['host_s']:>9.1f}")
        if len(r["threads"]) > 1:
            for t, tv in r["threads"].items():
                print(f"    -> hilo {t}: {tv['insts']:>12,.0f} instrucciones, IPC {tv['ipc']:.3f}")
    return 0

if __name__ == "__main__":
    a = [x for x in sys.argv[1:] if x != "--csv"]
    sys.exit(main(a, "--csv" in sys.argv))

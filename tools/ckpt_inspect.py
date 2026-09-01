#!/usr/bin/env python3
"""Inspecciona un .ckpt de RMC: header, registros, regiones, FDs y bytes en RIP."""
import struct, sys

HDR_SZ, REGS_OFF, REGS_SZ = 4480, 64, 4352
ROIRIP_OFF, STACKVA_OFF   = 4416, 4424
REGION_SZ, FD_SZ          = 104, 272

RNAMES = ["rax","rbx","rcx","rdx","rsi","rdi","rbp","rsp",
          "r8","r9","r10","r11","r12","r13","r14","r15",
          "rip","rflags","cs","ss","ds","es","fs","gs","fs_base","gs_base"]

def main(path, extra_addr=None):
    f = open(path, "rb")
    hdr = f.read(HDR_SZ)
    magic, ver = struct.unpack_from("<QI", hdr, 0)
    nreg, nfds = struct.unpack_from("<II", hdr, 12)
    roi_rip, stack_va = struct.unpack_from("<QQ", hdr, ROIRIP_OFF)
    print(f"magic=0x{magic:x} ver={ver} num_regions={nreg} num_fds={nfds}")
    print(f"roi_entry_rip=0x{roi_rip:x}  stack_va=0x{stack_va:x}")

    vals = struct.unpack_from("<26Q", hdr, REGS_OFF)
    print("\n--- REGISTROS ---")
    for n, v in zip(RNAMES, vals):
        print(f"  {n:>8} = 0x{v:016x}  ({v if v < 2**63 else v-2**64})")
    fpsize = struct.unpack_from("<I", hdr, REGS_OFF + 208)[0]
    fpregs = hdr[REGS_OFF+256 : REGS_OFF+256+64]
    print(f"  fpregs_size = {fpsize}")
    print(f"  fpregs[0:32] = {fpregs[:32].hex()}")

    regions = []
    for i in range(nreg):
        b = f.read(REGION_SZ)
        start, end = struct.unpack_from("<QQ", b, 0)
        prot, flags = struct.unpack_from("<II", b, 16)
        foff, dsize = struct.unpack_from("<QQ", b, 24)
        name = b[40:104].split(b"\0")[0].decode(errors="replace")
        regions.append((start, end, prot, flags, foff, dsize, name))

    fds = []
    for i in range(nfds):
        b = f.read(FD_SZ)
        fd, fl = struct.unpack_from("<ii", b, 0)
        off = struct.unpack_from("<q", b, 8)[0]
        p = b[16:272].split(b"\0")[0].decode(errors="replace")
        fds.append((fd, fl, off, p))

    print("\n--- REGIONES ---")
    print(f"{'start':>14} {'end':>14} {'sz':>10} {'prot':>5} {'flags':>5} {'file_off':>12} {'data_size':>10}  name")
    for s, e, p, fl, fo, ds, nm in regions:
        pr = ("r" if p & 1 else "-") + ("w" if p & 2 else "-") + ("x" if p & 4 else "-")
        print(f"0x{s:012x} 0x{e:012x} {e-s:10d} {pr:>5} 0x{fl:03x} {fo:12d} {ds:10d}  {nm}")

    print("\n--- FDs ---")
    for fd, fl, off, p in fds:
        print(f"  fd={fd} flags=0x{fl:x} offset={off} path={p}")

    targets = [("ROI RIP", roi_rip)]
    if extra_addr:
        targets.append(("EXTRA", int(extra_addr, 0)))
    for label, addr in targets:
        print(f"\n--- BYTES EN {label} 0x{addr:x} ---")
        hit = None
        for s, e, p, fl, fo, ds, nm in regions:
            if s <= addr < e:
                hit = (s, e, p, fl, fo, ds, nm)
                break
        if not hit:
            print("  !! direccion NO cubierta por ninguna region")
            continue
        s, e, p, fl, fo, ds, nm = hit
        print(f"  region 0x{s:x}-0x{e:x} '{nm}' data_size={ds} file_off={fo} flags=0x{fl:x}")
        if ds == 0:
            print("  !! la region NO tiene payload (SKIP)")
            continue
        delta = addr - s
        pre = 16
        f.seek(fo + delta - pre)
        blob = f.read(48)
        print(f"  [-16] {blob[:pre].hex(' ')}")
        print(f"  [RIP] {blob[pre:].hex(' ')}")
        with open(f"/tmp/at_{addr:x}.bin", "wb") as g:
            g.write(blob[pre:])
        with open(f"/tmp/at_{addr:x}_pre.bin", "wb") as g:
            g.write(blob)
    f.close()

if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else None)

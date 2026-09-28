"""
rmc_common.py - Helpers compartidos por las configs de gem5 de RMC.

Eleccion del loader: el break inicial de un binario estatico es el final de
su segmento mas alto. build/loader lo tiene en ~0x200xxxxx (correcto para
objetivos no PIE, cuyo heap queda por debajo) y build/loader_pie en
0x5555_0000_xxxx (correcto para PIE, cuyo heap queda justo encima). El
loader mueve el break al final del heap restaurado y el coste en gem5 es
lineal en la distancia, asi que se elige segun el [heap] del checkpoint.
"""
import os
import struct

HDR_SZ, REGION_SZ = 4480, 104
CKPT_FLAG_HEAP = 0x04
PIE_HEAP_MIN = 1 << 32   # heaps por encima de 4 GiB: objetivo PIE


def ckpt_heap_end(path):
    """Final del [heap] del checkpoint (0 si no tiene)."""
    with open(path, "rb") as f:
        hdr = f.read(HDR_SZ)
        nreg = struct.unpack_from("<I", hdr, 12)[0]
        heap_end = 0
        for _ in range(nreg):
            b = f.read(REGION_SZ)
            _start, end = struct.unpack_from("<QQ", b, 0)
            flags = struct.unpack_from("<I", b, 20)[0]
            if flags & CKPT_FLAG_HEAP:
                heap_end = max(heap_end, end)
    return heap_end


def pick_loader(ckpt, loader, loader_pie=None):
    """build/loader_pie para checkpoints PIE si existe, build/loader si no."""
    if loader_pie is None:
        loader_pie = loader + "_pie"
    if os.path.exists(loader_pie) and ckpt_heap_end(ckpt) >= PIE_HEAP_MIN:
        return loader_pie
    return loader


if __name__ == "__main__":
    # Uso desde scripts: rmc_common.py <ckpt> [build_dir] -> ruta del loader
    import sys
    if len(sys.argv) < 2:
        sys.exit("uso: rmc_common.py <ckpt> [build_dir]")
    build = sys.argv[2] if len(sys.argv) > 2 else os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "..", "build")
    print(os.path.normpath(pick_loader(sys.argv[1], os.path.join(build, "loader"))))

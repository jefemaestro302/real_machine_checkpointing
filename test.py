import struct
with open("Tailbench/tailbench/silo/tailbench_dump.ckpt", "rb") as f:
    f.seek(0xb4fff30 + 0x7fedb8)
    print("Return address at 0x7fedb8 offset: " + hex(struct.unpack("<Q", f.read(8))[0]))
    f.seek(0xb4fff30 + 0x7fdd90)
    print("0x7ffff07fdd90: " + hex(struct.unpack("<Q", f.read(8))[0]))

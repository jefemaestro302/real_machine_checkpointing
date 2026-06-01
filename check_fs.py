import struct
import sys

def parse_header(path):
    with open(path, "rb") as f:
        data = f.read(256)
        # struct layout:
        # uint64 magic
        # uint32 version
        # uint32 num_regions
        # ckpt_regs_t regs (144 bytes)
        # uint64 roi_entry_rip
        # uint64 stack_va
        
        magic, version, num_regions = struct.unpack_from("<QII", data, 0)
        print(f"Magic: {magic:x}, Version: {version}, Regions: {num_regions}")
        
        # regs start at offset 16
        regs_data = data[16:16+144]
        regs = struct.unpack("<18Q", regs_data)
        
        # regs is: rax, rbx, rcx, rdx, rsi, rdi, rbp, rsp
        # r8, r9, r10, r11, r12, r13, r14, r15
        # rip, rflags
        
        # Then we have segments and bases:
        # uint64_t cs, ss, ds, es, fs, gs;
        # uint64_t fs_base, gs_base;
        seg_data = data[16+144 : 16+144 + 48]
        cs, ss, ds, es, fs, gs = struct.unpack("<6Q", seg_data[:48])
        # Wait, the C struct says:
        # uint64 cs, ss, ds, es, fs, gs;  <-- Actually, wait. The ASM code does:
        # movw %cs, 144(%rsp)
        # So it stores them as 16-bit words!
        
parse_header("Tailbench/tailbench/silo/tailbench_dump.ckpt")

import struct
import sys

def parse_ckpt(filepath):
    with open(filepath, 'rb') as f:
        hdr_data = f.read(288)
        magic, version, num_regions = struct.unpack('<QII', hdr_data[:16])
        print(f"Magic: {magic:x}, Version: {version}, Regions: {num_regions}")
        
        for i in range(num_regions):
            reg_data = f.read(104)
            start, end, prot, flags, f_off, d_size = struct.unpack('<QQIIQQ', reg_data[:40])
            name = reg_data[40:].decode('utf-8', errors='ignore').rstrip('\x00')
            print(f"[{i:02d}] {start:x}-{end:x} prot={prot} flags={flags} off={f_off:x} size={d_size:x} {name}")

if __name__ == '__main__':
    parse_ckpt(sys.argv[1])

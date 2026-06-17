import sys
import struct

def parse_ckpt(filepath):
    with open(filepath, 'rb') as f:
        f.read(288) # skip header
        for i in range(2):
            reg_data = f.read(104)
            print(f"Region {i}: {reg_data[:40].hex()}")
            print(struct.unpack('<QQIIQQ', reg_data[:40]))

if __name__ == '__main__':
    parse_ckpt(sys.argv[1])

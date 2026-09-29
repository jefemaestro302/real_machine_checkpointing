/*
 * test_page_colour.c - Physical page placement of the restored process.
 *
 * Streams over a 192 KiB buffer: bigger than half of the 256 KiB L2 of the
 * gem5 configs, smaller than all of it. The L2 set index (64 B lines,
 * 8 ways, 512 sets) takes address bits 6-14, so bits 12-14 come from the
 * physical page number: the buffer only fits if its pages cover all 8
 * page colours.
 *
 * - --restore direct: gem5 allocates each run of checkpointed pages
 *   contiguously -> 8 colours, the buffer fits in L2 (~0.5% L2 misses).
 * - --restore loader: the loader memcpy()s from the mmap'd .ckpt, so source
 *   and target pages are faulted in alternately and the target gets every
 *   other physical page -> 4 colours, half of the L2 -> ~100% L2 misses.
 *
 *   gcc -O2 -mno-avx -mno-avx2 -fPIE -pie -o test_page_colour test/test_page_colour.c
 *   launch_scripts/gen_ckpt.sh -t 300000000 -o pc.ckpt -- ./test_page_colour
 *   gem5.opt x86_mixed.py --loader build/loader --ckpts pc.ckpt \
 *       --restore direct|loader --maxinsts 3000000
 *   grep system.l2cache.overallMisses::total m5out/stats.txt
 */
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

#define WS (192 * 1024)

int main(void)
{
    volatile unsigned char *buf = malloc(WS);
    for (int i = 0; i < WS; i++)          /* non-zero: part of the payload */
        buf[i] = (unsigned char)(i * 7 + 1);

    unsigned long sum = 0;
    for (unsigned long r = 0;; r++) {     /* checkpointed in here (-t) */
        for (int i = 0; i < WS; i += 64)
            sum += buf[i];
        if ((r & 0xffff) == 0) {
            char m[64];
            int n = snprintf(m, sizeof m, "PAGE COLOUR round %lu %lu\n", r, sum);
            (void)!write(1, m, n);
        }
    }
}

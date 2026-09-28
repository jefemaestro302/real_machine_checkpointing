/*
 * test_static_malloc.c - Heap growth/shrink after restoring a static
 * non-PIE program (heap BELOW the loader's program break).
 *
 * The checkpoint is taken with ckpt_dump() right before a malloc/free
 * phase that grows the heap well past its size at dump time and then
 * frees it (so glibc trims it with a negative sbrk). In gem5 this only
 * works if the loader moved the program break to the target's heap end.
 *
 *   gcc -O2 -static -no-pie -mno-avx -o test_static_malloc \
 *       test/test_static_malloc.c src/dumper.c src/dumper_asm.S
 *   setarch -R ./test_static_malloc sm.ckpt
 *   (gem5) launch_scripts/run_st_timing.sh sm.ckpt 2000000000 atomic
 *
 * Prints "STATIC MALLOC OK".
 */
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "../src/dumper.h"

int main(int argc, char **argv)
{
    void *warm = malloc(1 << 16);          /* make sure [heap] exists */
    memset(warm, 1, 1 << 16);

    if (ckpt_dump(argc > 1 ? argv[1] : "sm.ckpt") < 0) return 1;

    enum { N = 256 };
    static char *p[N];
    for (int round = 0; round < 4; round++) {
        for (int i = 0; i < N; i++) {       /* ~16 MiB in 64 KiB blocks: brk growth */
            p[i] = malloc(64 * 1024 - 64);
            if (!p[i]) { (void)!write(1, "MALLOC FAILED\n", 14); return 2; }
            memset(p[i], i, 64 * 1024 - 64);
        }
        for (int i = N - 1; i >= 0; i--)    /* free top-down: heap trim */
            free(p[i]);
    }
    free(warm);
    static const char ok[] = "STATIC MALLOC OK\n";
    (void)!write(1, ok, sizeof(ok) - 1);
    return 0;
}

/*
 * test_signal_malloc.c - Checkpoint taken while the program lives in malloc,
 * and malloc still working after the restore.
 *
 * The program does nothing but malloc/free of sizes that bypass the tcache,
 * so the arena lock is held a large fraction of the time (libckpt's timer
 * thread makes the process multi-threaded, so glibc really takes it), and
 * the heap keeps growing and being trimmed with brk().
 *  - A dumper that calls malloc (fopen, stdio...) from the signal handler
 *    deadlocks when the signal lands inside malloc: no checkpoint.
 *  - A restore that leaves the process with the loader's program break
 *    makes glibc corrupt its heap on the next trim ("double free or
 *    corruption (out)") or fault on the next growth.
 *
 *   launch_scripts/gen_ckpt.sh -t 200000000 -o m.ckpt -- ./test_signal_malloc
 *
 * Output: "MALLOC chunk N ok" per chunk, then "MALLOC OK".
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(void)
{
    enum { SLOTS = 64 };
    void *slot[SLOTS] = {0};
    unsigned x = 12345;
    char line[64];
    for (int chunk = 0; chunk < 200; chunk++) {
        for (int i = 0; i < 20000; i++) {
            x = x * 1103515245u + 12345u;
            int k = (x >> 8) % SLOTS;
            free(slot[k]);
            slot[k] = malloc(2048 + ((x >> 16) % 65536));
            if (slot[k]) memset(slot[k], 0, 16);
        }
        int n = snprintf(line, sizeof(line), "MALLOC chunk %d ok\n", chunk);
        (void)!write(1, line, (size_t)n);
    }
    static const char ok[] = "MALLOC OK\n";
    (void)!write(1, ok, sizeof(ok) - 1);
    return 0;
}

/*
 * test_signal_malloc.c - Checkpoint taken while the program lives in malloc.
 *
 * The program does nothing but malloc/free of sizes that bypass the tcache,
 * so the arena lock is held a large fraction of the time. libckpt's timer
 * thread makes the process multi-threaded, so glibc really takes that lock.
 * A dumper that calls malloc (fopen, stdio...) from the signal handler
 * deadlocks when the signal lands inside malloc: the run never finishes.
 *
 *   timeout 20 env LD_PRELOAD=build/libckpt.so CKPT_AFTER_NS=<random> \
 *       CKPT_OUTPUT=m.ckpt ./test_signal_malloc
 *
 * Prints "MALLOC OK" and exits 0 after ~2 s of work; with the old dumper a
 * fraction of the runs hang (timeout exit code 124).
 */
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>

int main(void)
{
    enum { SLOTS = 64 };
    void *slot[SLOTS] = {0};
    unsigned x = 12345;
    struct timespec t0, t;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    for (;;) {
        for (int i = 0; i < 100000; i++) {
            x = x * 1103515245u + 12345u;
            int k = (x >> 8) % SLOTS;
            free(slot[k]);
            slot[k] = malloc(2048 + ((x >> 16) % 65536));
            if (slot[k]) memset(slot[k], 0, 16);
        }
        clock_gettime(CLOCK_MONOTONIC, &t);
        if (t.tv_sec - t0.tv_sec >= 2) break;
    }
    static const char ok[] = "MALLOC OK\n";
    (void)!write(1, ok, sizeof(ok) - 1);
    return 0;
}

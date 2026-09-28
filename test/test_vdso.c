/*
 * test_vdso.c - Does the clock still work after a restore?
 *
 * glibc calls clock_gettime()/gettimeofday()/time() through the vDSO. The
 * checkpoint contains the HOST's vDSO code and its [vvar] data page frozen
 * at dump time; executed after a restore (above all inside gem5) it
 * returns a stuck or meaningless clock. The loader redirects those vDSO
 * entry points to real syscalls.
 *
 * The program spins; each round it checks that CLOCK_MONOTONIC advanced
 * across a busy loop. Checkpoint it by timer and restore it:
 *
 *   setarch -R env LD_PRELOAD=build/libckpt.so CKPT_AFTER_NS=300000000 \
 *       CKPT_OUTPUT=v.ckpt ./test_vdso
 *   setarch -R build/loader_pie v.ckpt --native
 *
 * Prints "CLOCK OK" or "CLOCK STUCK" (exit 3).
 */
#include <stdio.h>
#include <time.h>
#include <unistd.h>
#include <sys/time.h>

static long long ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

int main(void)
{
    volatile unsigned long sink = 0;
    for (int round = 0; round < 40; round++) {
        long long t0 = ns();
        struct timeval tv0;
        gettimeofday(&tv0, NULL);
        for (unsigned long i = 0; i < 20000000UL; i++) sink += i;
        long long t1 = ns();
        struct timeval tv1;
        gettimeofday(&tv1, NULL);
        long long dtv = (tv1.tv_sec - tv0.tv_sec) * 1000000LL + (tv1.tv_usec - tv0.tv_usec);
        if (t1 <= t0 || dtv <= 0) {
            static const char m[] = "CLOCK STUCK\n";
            (void)!write(1, m, sizeof(m) - 1);
            _exit(3);
        }
    }
    static const char ok[] = "CLOCK OK\n";
    (void)!write(1, ok, sizeof(ok) - 1);
    return 0;
}

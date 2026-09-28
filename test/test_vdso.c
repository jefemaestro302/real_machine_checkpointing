/*
 * test_vdso.c - Does the clock still work after a restore?
 *
 * glibc calls clock_gettime()/gettimeofday() through the vDSO. The
 * checkpoint contains the HOST's vDSO code and its [vvar] data page frozen
 * at dump time; executed after a restore inside gem5 it keeps returning the
 * same time. The loader redirects those vDSO entry points to real syscalls.
 *
 * Each round samples both clocks around a busy loop:
 *   - strictly increasing          -> "CLOCK round N ok"
 *   - going backwards              -> "CLOCK round N jump" (expected once:
 *     the round that spans the checkpoint compares a host time with a
 *     simulated one)
 *   - exactly the same value twice -> "CLOCK STUCK", exit 3
 *
 *   launch_scripts/gen_ckpt.sh -t 300000000 -o v.ckpt -- ./test_vdso
 *
 * Ends with "CLOCK OK".
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

static long long us(void)
{
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return tv.tv_sec * 1000000LL + tv.tv_usec;
}

int main(void)
{
    volatile unsigned long sink = 0;
    char line[64];
    for (int round = 0; round < 1200; round++) {    /* ~10M instructions each */
        long long t0 = ns(), u0 = us();
        for (unsigned long i = 0; i < 2000000UL; i++) sink += i;
        long long t1 = ns(), u1 = us();
        int n;
        if (t1 == t0 || u1 == u0) {
            static const char m[] = "CLOCK STUCK\n";
            (void)!write(1, m, sizeof(m) - 1);
            _exit(3);
        } else if (t1 < t0 || u1 < u0) {
            n = snprintf(line, sizeof(line), "CLOCK round %d jump\n", round);
        } else {
            n = snprintf(line, sizeof(line), "CLOCK round %d ok\n", round);
        }
        (void)!write(1, line, (size_t)n);
    }
    static const char ok[] = "CLOCK OK\n";
    (void)!write(1, ok, sizeof(ok) - 1);
    return 0;
}

/*
 * test_redzone.c - Detects corruption of the x86-64 red zone on restore.
 *
 * leaf_spin() is a leaf function that keeps live data in the 128-byte red
 * zone below %rsp (as compiled leaf functions legitimately do) and spins
 * checking it. Almost all the run time is spent there, so a checkpoint
 * taken by signal (CKPT_AFTER_NS / SIGUSR1) almost always interrupts it.
 * If the loader writes below the restored %rsp (e.g. by pushing RIP/RFLAGS
 * onto the target stack), the check fails right after the restore.
 *
 *   launch_scripts/gen_ckpt.sh -t 300000000 -o rz.ckpt -- ./test_redzone
 *   setarch -R build/loader_pie rz.ckpt --native      # native check
 *
 * Output: one "REDZONE round N ok" line per round (in gem5, with a bounded
 * --maxinsts, they show how far the ROI got), then "REDZONE OK" (exit 0),
 * or "REDZONE CORRUPT" (exit 2).
 */
#include <stdio.h>
#include <unistd.h>

long leaf_spin(long iters);

__asm__ (
    "    .text\n"
    "    .globl leaf_spin\n"
    "    .type leaf_spin, @function\n"
    "leaf_spin:\n"
    "    movabsq $0x1122334455667788, %rax\n"
    "    movq    %rax, -8(%rsp)\n"
    "    movq    %rax, -16(%rsp)\n"
    "    movq    %rax, -24(%rsp)\n"
    "1:  cmpq    %rax, -8(%rsp)\n"
    "    jne     2f\n"
    "    cmpq    %rax, -16(%rsp)\n"
    "    jne     2f\n"
    "    cmpq    %rax, -24(%rsp)\n"
    "    jne     2f\n"
    "    decq    %rdi\n"
    "    jnz     1b\n"
    "    xorl    %eax, %eax\n"
    "    ret\n"
    "2:  movl    $1, %eax\n"
    "    ret\n"
    "    .size leaf_spin, .-leaf_spin\n"
);

int main(void)
{
    char line[64];
    for (int r = 0; r < 300; r++) {                 /* ~28M instructions each */
        if (leaf_spin(4000000L)) {
            static const char m[] = "REDZONE CORRUPT\n";
            (void)!write(1, m, sizeof(m) - 1);
            _exit(2);
        }
        int n = snprintf(line, sizeof(line), "REDZONE round %d ok\n", r);
        (void)!write(1, line, (size_t)n);
    }
    static const char ok[] = "REDZONE OK\n";
    (void)!write(1, ok, sizeof(ok) - 1);
    _exit(0);
}

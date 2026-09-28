/*
 * test_redzone.c - Detects corruption of the x86-64 red zone on restore.
 *
 * leaf_spin() is a leaf function that keeps live data in the 128-byte red
 * zone below %rsp (as compiled leaf functions legitimately do) and spins
 * checking it. Almost all the run time is spent there, so a checkpoint
 * taken by signal (CKPT_AFTER_NS / SIGUSR1) almost always interrupts it.
 * If the loader writes below the restored %rsp (e.g. by pushing RIP/RFLAGS
 * onto the target stack), the check fails after the restore.
 *
 *   LD_PRELOAD=build/libckpt.so CKPT_AFTER_NS=300000000 \
 *       CKPT_OUTPUT=rz.ckpt setarch -R ./test_redzone
 *   setarch -R build/loader rz.ckpt --native      # native check
 *
 * Prints "REDZONE OK" (exit 0) or "REDZONE CORRUPT" (exit 2).
 */
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
    for (int r = 0; r < 60; r++) {
        if (leaf_spin(20000000L)) {
            static const char m[] = "REDZONE CORRUPT\n";
            (void)!write(1, m, sizeof(m) - 1);
            _exit(2);
        }
    }
    static const char ok[] = "REDZONE OK\n";
    (void)!write(1, ok, sizeof(ok) - 1);
    _exit(0);
}

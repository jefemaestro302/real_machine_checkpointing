/*
 * dumper_asm.S - ckpt_dump(path): capture the caller's CPU state into a
 * ckpt_regs_t on the stack and hand it to ckpt_dump_impl(path, &regs).
 *
 * The frame is sizeof(ckpt_regs_t) = 4352 bytes, 64-byte aligned (the
 * struct is __attribute__((aligned(64))) because of fpregs). Offsets:
 *   0..120  rax rbx rcx rdx rsi rdi rbp rsp r8..r15
 *   128 rip   136 rflags   144..184 cs ss ds es fs gs
 *   192 fs_base   200 gs_base (filled in C via arch_prctl)
 *   208 fpregs_size (uint32)   256 fpregs[4096] (fxsave image, 512 B used)
 *
 * The saved state is the one right AFTER `call ckpt_dump` returns:
 *   rip = return address, rsp = caller's rsp after the ret.
 * The saved rax is 1, so on restore ckpt_dump() "returns" 1, while the
 * first (native) run returns ckpt_dump_impl's 0 / -1.
 */
    .text
    .globl ckpt_dump
    .type  ckpt_dump, @function

ckpt_dump:
    pushfq                          /* 8(%rbp) after the prologue: rflags  */
    pushq %rbp                      /* 0(%rbp): caller's rbp               */
    movq  %rsp, %rbp                /* 16(%rbp): return address            */
    subq  $4352, %rsp
    andq  $-64, %rsp                /* rsp -> ckpt_regs_t, 64-byte aligned */

    movq  $1,   0(%rsp)             /* rax seen by the caller on restore   */
    movq  %rbx, 8(%rsp)
    movq  %rcx, 16(%rsp)
    movq  %rdx, 24(%rsp)
    movq  %rsi, 32(%rsp)
    movq  %rdi, 40(%rsp)
    movq  0(%rbp), %rax
    movq  %rax, 48(%rsp)            /* rbp                                  */
    leaq  24(%rbp), %rax
    movq  %rax, 56(%rsp)            /* rsp once `ret` has popped the retaddr */
    movq  %r8,  64(%rsp)
    movq  %r9,  72(%rsp)
    movq  %r10, 80(%rsp)
    movq  %r11, 88(%rsp)
    movq  %r12, 96(%rsp)
    movq  %r13, 104(%rsp)
    movq  %r14, 112(%rsp)
    movq  %r15, 120(%rsp)
    movq  16(%rbp), %rax
    movq  %rax, 128(%rsp)           /* rip = return address                 */
    movq  8(%rbp), %rax
    movq  %rax, 136(%rsp)           /* rflags at the call site              */

    /* Segments */
    movq  $0, 144(%rsp)
    movw  %cs, 144(%rsp)
    movq  $0, 152(%rsp)
    movw  %ss, 152(%rsp)
    movq  $0, 160(%rsp)
    movw  %ds, 160(%rsp)
    movq  $0, 168(%rsp)
    movw  %es, 168(%rsp)
    movq  $0, 176(%rsp)
    movw  %fs, 176(%rsp)
    movq  $0, 184(%rsp)
    movw  %gs, 184(%rsp)

    /* fs_base, gs_base (fetched safely via arch_prctl in C later) */
    movq  $0, 192(%rsp)
    movq  $0, 200(%rsp)

    /* FPU/SSE state: without this, fpregs_size was left with whatever the
     * stack held and the loader could fxrstor garbage (#GP on a bad MXCSR) */
    movq  $512, 208(%rsp)           /* fpregs_size = 512 (+ zero padding)   */
    fxsave 256(%rsp)

    /* ckpt_dump_impl(path, &regs); path is still in %rdi, rsp is aligned */
    movq  %rsp, %rsi
    call  ckpt_dump_impl@PLT

    movq  %rbp, %rsp
    popq  %rbp
    addq  $8, %rsp                  /* drop the saved rflags               */
    ret
    .size ckpt_dump, .-ckpt_dump

    /* Non-executable stack: without this note the linker marks every
     * binary/.so that links this object as needing an executable stack. */
    .section .note.GNU-stack,"",@progbits

.global ckpt_dump
.type ckpt_dump, @function

ckpt_dump:
    subq $256, %rsp
    
    movq %rax, 0(%rsp)
    movq %rbx, 8(%rsp)
    movq %rcx, 16(%rsp)
    movq %rdx, 24(%rsp)
    movq %rsi, 32(%rsp)
    movq %rdi, 40(%rsp)
    movq %rbp, 48(%rsp)
    
    /* The original %rsp was %rsp + 256 (our alloc) + 8 (the return address) */
    leaq 264(%rsp), %rax
    movq %rax, 56(%rsp)
    
    movq %r8,  64(%rsp)
    movq %r9,  72(%rsp)
    movq %r10, 80(%rsp)
    movq %r11, 88(%rsp)
    movq %r12, 96(%rsp)
    movq %r13, 104(%rsp)
    movq %r14, 112(%rsp)
    movq %r15, 120(%rsp)
    
    /* RIP: Return address is at 256(%rsp) */
    movq 256(%rsp), %rax
    movq %rax, 128(%rsp)
    
    /* RFLAGS */
    pushfq
    popq %rax
    movq %rax, 136(%rsp)
    
    /* Segments */
    movq $0, 144(%rsp)
    movw %cs, 144(%rsp)
    movq $0, 152(%rsp)
    movw %ss, 152(%rsp)
    movq $0, 160(%rsp)
    movw %ds, 160(%rsp)
    movq $0, 168(%rsp)
    movw %es, 168(%rsp)
    movq $0, 176(%rsp)
    movw %fs, 176(%rsp)
    movq $0, 184(%rsp)
    movw %gs, 184(%rsp)
    
    /* fs_base, gs_base */
    rdfsbase %rax
    movq %rax, 192(%rsp)
    rdgsbase %rax
    movq %rax, 200(%rsp)
    
    /* Call ckpt_dump_impl(path, &regs) */
    /* path is already in %rdi */
    movq %rsp, %rsi
    /* align stack to 16 bytes before call */
    subq $8, %rsp
    call ckpt_dump_impl
    addq $8, %rsp
    
    addq $256, %rsp
    ret

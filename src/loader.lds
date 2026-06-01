/* Loader linker script: all segments above 0x20000000 */
OUTPUT_FORMAT(elf64-x86-64)
OUTPUT_ARCH(i386:x86-64)
ENTRY(_start)

SECTIONS {
    . = 0x20000000;

    .text  : { *(.text .text.*) }
    .rodata : { *(.rodata .rodata.*) }
    .data.rel.ro : { *(.data.rel.ro .data.rel.ro.*) }
    .got.plt : { *(.got.plt) }
    .got : { *(.got) }
    . = ALIGN(0x1000);
    .data : { *(.data .data.*) }
    .bss  : { *(.bss .bss.*) *(COMMON) }
    . = ALIGN(0x1000);

    /* Discard unnecessary sections */
    /DISCARD/ : {
        *(.note.*)
        *(.comment)
        *(.eh_frame)
        *(.eh_frame_hdr)
    }
}

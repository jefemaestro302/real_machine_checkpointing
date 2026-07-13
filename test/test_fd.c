#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <string.h>

#include "../src/checkpoint.h"
#include "../src/dumper.h"

int main(int argc, char *argv[]) {
    if (argc < 3) {
        printf("Usage: %s <input_file> <output_file>\n", argv[0]);
        return 1;
    }

    int fd_in = open(argv[1], O_RDONLY);
    if (fd_in < 0) {
        perror("open input");
        return 1;
    }

    int fd_out = open(argv[2], O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd_out < 0) {
        perror("open output");
        return 1;
    }

    char buf[6] = {0};
    
    // 1. Read first 5 bytes from input
    read(fd_in, buf, 5);
    printf("[APP] Before checkpoint: read '%s' from fd %d\n", buf, fd_in);
    
    // 2. Write to output
    write(fd_out, "HELLO\n", 6);
    
    printf("[APP] Taking checkpoint now...\n");
    if (ckpt_dump("dump.ckpt") == 0) {
        printf("[APP] First run after dump returned!\n");
    } else {
        printf("[APP] Restored from dump! (or dump failed)\n");
    }

    // 3. Read next 5 bytes from input
    memset(buf, 0, 6);
    ssize_t n = read(fd_in, buf, 5);
    if (n > 0) {
        printf("[APP] After checkpoint: read '%s' from fd %d\n", buf, fd_in);
    } else {
        printf("[APP] After checkpoint: read failed or EOF on fd %d\n", fd_in);
    }
    
    // 4. Write to output again (should go to /dev/null if restored)
    ssize_t w = write(fd_out, "WORLD\n", 6);
    if (w > 0) {
        printf("[APP] After checkpoint: successfully wrote to output fd %d\n", fd_out);
    } else {
        printf("[APP] After checkpoint: write failed on fd %d\n", fd_out);
    }

    close(fd_in);
    close(fd_out);
    
    printf("[APP] Done.\n");
    return 0;
}

#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <string.h>

#include "../src/checkpoint.h"
#include "../src/dumper.h"

int main(int argc, char *argv[]) {
    if (argc < 3) {
        printf("Usage: %s <input_file> <output_file> [checkpoint (dump.ckpt)]\n", argv[0]);
        return 1;
    }
    const char *ckpt = argc > 3 ? argv[3] : "dump.ckpt";

    /* Unbuffered: a pending stdout buffer would be part of the checkpoint
     * and be printed a second time after the restore. */
    setvbuf(stdout, NULL, _IONBF, 0);

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
    (void)!read(fd_in, buf, 5);
    printf("[APP] Before checkpoint: read '%s' from fd %d\n", buf, fd_in);
    
    // 2. Write to output
    (void)!write(fd_out, "HELLO\n", 6);
    
    printf("[APP] Taking checkpoint now...\n");
    int rc = ckpt_dump(ckpt);
    if (rc == 0) {
        printf("[APP] First run after dump returned!\n");
    } else if (rc == 1) {
        printf("[APP] Restored from dump!\n");
    } else {
        printf("[APP] Dump FAILED\n");
        return 1;
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

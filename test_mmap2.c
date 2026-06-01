#include <stdio.h>
#include <sys/mman.h>

int main() {
    void *m = mmap((void *)0x7ffff7ffc000, 0x1000, PROT_READ | PROT_WRITE,
                   MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, -1, 0);
    if (m == MAP_FAILED) perror("mmap 0x7ffff7ffc000");
    else printf("mmap 0x7ffff7ffc000 success\n");
    return 0;
}

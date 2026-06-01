#include <stdio.h>
#include <sys/mman.h>
#include <stdlib.h>

int main() {
    void *m = mmap((void *)0x7ffff7ffc000, 0x1000, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, -1, 0);
    if (m == MAP_FAILED) {
        perror("mmap");
        return 1;
    }
    printf("Success: %p\n", m);
    return 0;
}

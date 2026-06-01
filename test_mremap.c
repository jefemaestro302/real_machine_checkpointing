#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <sys/mman.h>
#include <unistd.h>

int main() {
    FILE *f = fopen("/proc/self/maps", "r");
    char line[256];
    uint64_t vdso_start = 0, vdso_end = 0;
    while (fgets(line, sizeof(line), f)) {
        if (strstr(line, "[vdso]")) {
            sscanf(line, "%lx-%lx", &vdso_start, &vdso_end);
            break;
        }
    }
    fclose(f);
    printf("Original vdso: %lx - %lx\n", vdso_start, vdso_end);
    
    void *new_addr = (void*)0x7ffff7ffa000;
    size_t sz = vdso_end - vdso_start;
    
    void *ret = mremap((void*)vdso_start, sz, sz, MREMAP_MAYMOVE | MREMAP_FIXED, new_addr);
    if (ret == MAP_FAILED) {
        perror("mremap");
        return 1;
    }
    printf("mremap successful to %p\n", ret);
    
    // Check if we can still call a vdso function, like gettimeofday
    // Wait, glibc might cache the old vdso address, so calling gettimeofday through glibc might segfault!
    // But this is just a test to see if mremap succeeds.
    return 0;
}

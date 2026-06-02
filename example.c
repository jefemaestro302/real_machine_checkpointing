#include <stdio.h>
#include <unistd.h>

void target_function(int iteration) {
    printf("[Target] Inside target_function! Iteration = %d\n", iteration);
    // The checkpoint will happen right here if CKPT_AT_SYMBOL=target_function
}

int main() {
    printf("[Example] Starting application...\n");
    printf("[Example] PID = %d. Send SIGUSR1 to checkpoint, or let it hit target_function at iteration 3!\n", getpid());

    for (int i = 1; i <= 10; i++) {
        printf("[Example] Iteration %d\n", i);
        if (i == 3) {
            target_function(i);
        }
        sleep(1);
    }
    
    printf("[Example] Done!\n");
    return 0;
}

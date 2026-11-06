#include <pthread.h>
#include <stdio.h>
#include <unistd.h>

/* Al posto di exit(): segnala all'app la terminazione e chiude solo il thread dell'emulatore. */
void ar_temu_exit(int code) {
    char msg[64];
    int n = snprintf(msg, sizeof msg, "\n__AR_VM_EXIT__ %d\n", code);
    if (n > 0) write(STDOUT_FILENO, msg, (size_t)n);
    pthread_exit(NULL);
}

int ar_unavailable(void) { return -1; }

/* Marcatore usato dalla CI per verificare che l'emulatore sia collegato nell'IPA. */
__attribute__((used)) const char ar_tinyemu_marker[] = "AR_TINYEMU_LINKED_v1";

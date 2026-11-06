#include "ARVMBridge.h"
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* Simbolo fornito da libtemu.a (TinyEMU compilato con -Dmain=temu_main).
   È weak: se la libreria non è collegata vale NULL e la VM risulta non disponibile. */
extern int temu_main(int argc, char **argv) __attribute__((weak_import));

static char *g_argv[4];
static int g_started = 0;

int ar_vm_available(void) {
    return temu_main != NULL ? 1 : 0;
}

static void *ar_vm_thread(void *arg) {
    (void)arg;
    temu_main(2, g_argv);
    return NULL;
}

int ar_vm_start(const char *config_path, int *stdin_write, int *stdout_read) {
    if (temu_main == NULL) return -1;
    if (g_started) return -5;
    int in_pipe[2], out_pipe[2];
    if (pipe(in_pipe) != 0) return -2;
    if (pipe(out_pipe) != 0) return -2;
    signal(SIGPIPE, SIG_IGN);
    fflush(stdout);
    /* L'emulatore usa stdin/stdout come console seriale: li ridirigiamo sulle pipe. */
    if (dup2(in_pipe[0], STDIN_FILENO) < 0) return -3;
    if (dup2(out_pipe[1], STDOUT_FILENO) < 0) return -3;
    close(in_pipe[0]);
    close(out_pipe[1]);
    setvbuf(stdout, NULL, _IONBF, 0);
    g_argv[0] = strdup("temu");
    g_argv[1] = strdup(config_path);
    g_argv[2] = NULL;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setstacksize(&attr, 16 * 1024 * 1024);
    pthread_t thread;
    if (pthread_create(&thread, &attr, ar_vm_thread, NULL) != 0) return -4;
    pthread_detach(thread);
    g_started = 1;
    *stdin_write = in_pipe[1];
    *stdout_read = out_pipe[0];
    return 0;
}

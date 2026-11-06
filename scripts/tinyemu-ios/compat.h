/* Adattamenti per compilare TinyEMU per iOS (incluso in ogni file con -include). */
#ifndef AR_TINYEMU_COMPAT_H
#define AR_TINYEMU_COMPAT_H
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/mount.h>
#include <sys/time.h>
#include <pthread.h>

/* L'emulatore gira in un thread dell'app: exit() terminerebbe l'intera app. */
void ar_temu_exit(int code) __attribute__((noreturn));
#define exit(code) ar_temu_exit(code)

/* system(), fork(), exec*() non sono utilizzabili su iOS */
int ar_unavailable(void);
#define system(x) ar_unavailable()
#define fork() ar_unavailable()
#define execvp(a, b) ar_unavailable()
#define execv(a, b) ar_unavailable()
#define execl(...) ar_unavailable()

/* Nomi Linux dei timestamp in struct stat */
#ifndef st_atim
#define st_atim st_atimespec
#define st_mtim st_mtimespec
#define st_ctim st_ctimespec
#endif

#ifndef O_LARGEFILE
#define O_LARGEFILE 0
#endif
#ifndef O_NOATIME
#define O_NOATIME 0
#endif
#define lseek64 lseek
#define off64_t off_t
#define fdatasync fsync
#endif

#ifndef ARVMBridge_h
#define ARVMBridge_h

/// 1 se l'emulatore (TinyEMU) è stato collegato nell'app, 0 altrimenti.
int ar_vm_available(void);

/// Avvia l'emulatore RISC-V in un thread dell'app. La console della VM viene collegata
/// a due pipe: `stdin_write` (host -> VM) e `stdout_read` (VM -> host).
/// Restituisce 0 se l'avvio è riuscito, un valore negativo in caso di errore.
int ar_vm_start(const char *config_path, int *stdin_write, int *stdout_read);

#endif

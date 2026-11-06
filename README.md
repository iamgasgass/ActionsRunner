# Actions Runner per iOS

App iOS (SwiftUI, iOS 17+) che importa un **file .zip contenente una repository**, legge i workflow in
`.github/workflows/*.yml` e li esegue in due modi, senza librerie di terze parti:

- **Sul dispositivo**: motore Actions + VM Linux integrata, nessun account né server;
- **Su GitHub** (facoltativo, con un token): l'app carica il progetto su un branch, avvia il workflow
  sui **runner reali di GitHub** (Ubuntu, Windows, **macOS con Xcode**) e mostra in tempo reale job,
  step, log, annotazioni e artifact, che si scaricano nell'app (es. l'IPA).

## Architettura

```
┌──────────────────────────── App iOS ────────────────────────────┐
│  Motore GitHub Actions (Swift)                                  │
│  YAML · espressioni ${{ }} · contesti · matrix · needs · if     │
│  GITHUB_OUTPUT/ENV/PATH/STATE/STEP_SUMMARY · comandi ::         │
│  azioni composite · reusable workflow · artifact · cache        │
│                     │                         │                 │
│        step run: / azioni node*         fallback                │
│                     ▼                         ▼                 │
│  ┌──────────── VM Linux ────────────┐  Interprete bash          │
│  │ TinyEMU (RISC-V 64, in-process)  │  integrato (Swift,        │
│  │ Linux + Alpine riscv64           │  100+ comandi)            │
│  │ bash git python3 node make curl… │                           │
│  │ /home/runner ⇄ 9p ⇄ cartella app │                           │
│  └──────────────────────────────────┘                           │
└─────────────────────────────────────────────────────────────────┘
```

- **Motore Actions** scritto da zero in Swift: semantica di GitHub per espressioni, contesti, matrix
  (`include`/`exclude`), `needs`, condizioni con `success()` implicito, `continue-on-error`,
  `timeout-minutes`, `defaults.run`, file d'ambiente, comandi di workflow, maschere dei secrets,
  azioni composite (locali e remote), azioni JavaScript, reusable workflow, `actions/checkout`,
  `upload-artifact`, `download-artifact`, `cache`.
- **VM Linux integrata**: TinyEMU (emulatore RISC-V di Fabrice Bellard, MIT) compilato nell'app come
  libreria statica e avviato in un thread. Dentro gira un vero Linux con Alpine riscv64:
  gli step `run:` vengono eseguiti da **bash reale** con `bash -e {0}` /
  `bash --noprofile --norc -eo pipefail {0}` come sul runner Ubuntu, con i workspace in
  `/home/runner/work/<repo>/<repo>`. Le **azioni JavaScript** (`runs.using: node20/node24`)
  vengono eseguite con `node`, con `INPUT_*`, `pre`/`post` e `STATE_*` come fa il runner.
  La cartella dell'app è condivisa con la VM tramite virtio-9p; la rete funziona in user-mode (slirp).
- **Interprete bash integrato** (Swift): usato se la VM non è inclusa o se scegli
  "Interprete integrato" nelle impostazioni.
- **Parser YAML** e **ZIP** scritti da zero (ZIP con DEFLATE del framework Compression di Apple).

Unico accesso di rete facoltativo: il download (anonimo) delle azioni `uses: owner/repo@ref` non
ancora in cache, come fa il runner di GitHub. Dopo il primo download funzionano anche offline.

## Esegui su GitHub

Per i workflow che richiedono macOS/Xcode (o qualunque cosa debba girare esattamente sui runner di GitHub).

1. **Impostazioni → Account GitHub**: incolla un token (classic con scope `repo` e `workflow`, oppure
   fine-grained con Contents, Actions, Workflows, Secrets, Variables in lettura/scrittura). Resta nel
   portachiavi del dispositivo e viene inviato solo a `api.github.com`.
2. Nel workflow: **Esegui su GitHub** → scegli o crea un repository (privato consigliato) e il branch.
3. L'app:
   - calcola in locale gli SHA-1 git dei file e carica **solo quelli che GitHub non ha** (Git Data API,
     4 upload in parallelo, cache dei blob già inviati);
   - crea un commit con l'albero **identico al progetto** (permessi eseguibili e symlink inclusi);
   - avvia il workflow con **workflow_dispatch** (con gli input) se il workflow lo dichiara, altrimenti
     con il **push** del commit, come farebbe `git push`; l'ID della run arriva dalla risposta di
     GitHub (`return_run_details`) o viene cercato per commit;
   - facoltativamente copia nel repository i **secrets** (cifrati sul dispositivo con la sealed box di
     libsodium, reimplementata e verificata contro libsodium) e le **variabili** configurate nell'app;
   - segue la run con richieste condizionali (ETag: le risposte 304 non consumano il limite di
     GitHub), intervallo adattivo (3 s in esecuzione, 5 s in coda, rallenta se il limite si avvicina);
   - scarica i log di ogni job (anche parziali durante l'esecuzione) e li divide per step usando gli
     orari, con gruppi, errori e avvisi come su github.com; legge le annotazioni;
   - elenca e scarica gli **artifact**, ne mostra il contenuto e condivide i singoli file (es. `.ipa`);
   - permette di **annullare** (anche forzato) e **rieseguire** (tutti i job, solo i falliti, con debug);
   - salva le run: dopo il riavvio dell'app riprende il monitoraggio; notifica la fine se l'app è in
     background.

Sono le stesse API che usa github.com: il comportamento è quello di GitHub, perché è GitHub a eseguire.

## Limiti onesti

- **Prestazioni**: la VM è un emulatore interpretato (iOS non permette JIT alle app normali).
  L'avvio richiede da decine di secondi ad alcuni minuti e i comandi pesanti (es. `npm install`,
  compilazioni C) sono molto più lenti che su un PC.
- **Niente Xcode/macOS sul dispositivo**: un job `runs-on: macos-*` eseguito sul dispositivo gira nella
  VM Linux, dove `xcodebuild`, `swift`, `codesign` non esistono (Apple non li distribuisce per Linux/iOS
  e la licenza ne consente l'uso solo su Mac): per questi job usa **Esegui su GitHub**.
  I container Docker non sono eseguibili sul dispositivo.
- La VM ha la memoria limitata dalle regole di iOS (impostabile, predefinita 512 MB).
- Kernel della VM: Linux 4.15 riscv64 dell'immagine ufficiale di TinyEMU; alcuni programmi molto recenti
  potrebbero richiedere un kernel più nuovo.

## Costruire l'app (GitHub Actions)

1. Carica questa repository su GitHub.
2. Il workflow `.github/workflows/build.yml` ha due job:
   - **linux-image** (Ubuntu): scarica kernel e firmware di TinyEMU e crea il rootfs Alpine riscv64
     (`scripts/build-linux-image.sh`; pacchetti personalizzabili con l'input `alpine_packages`),
     poi **collauda l'avvio** (`scripts/test-vm-boot.sh`): compila TinyEMU per Linux dallo stesso
     sorgente, avvia la VM con la stessa configurazione dell'app (kernel, cmdline `vm-cmdline.txt`,
     9p, rete) ed esegue comandi con il protocollo dell'agente. Se la VM non arriva a `__AR_READY__`
     o shell/bash/git/python3/9p non funzionano, l'immagine non viene pubblicata;
   - **build** (macOS 26): compila TinyEMU per iOS (`scripts/build-tinyemu.sh`: fork
     `fernandotcl/TinyEMU` con supporto iOS nativo, ripiego automatico sul sorgente originale),
     include l'immagine Linux, archivia l'app e produce l'**IPA non firmato**
     (artifact `ActionsRunner-unsigned-ipa`).
3. La VM è **obbligatoria**: se l'emulatore o l'immagine non sono disponibili la build fallisce, e prima
   di creare l'IPA viene verificato che `rootfs.ext2`, kernel, firmware ed emulatore siano davvero
   dentro l'app. Per un IPA senza VM avvia il workflow a mano con `allow_without_vm: true`.
4. Installa l'IPA con AltStore, SideStore, Sideloadly o TrollStore.
5. Opzionale: IPA firmato con i secrets `BUILD_CERTIFICATE_BASE64`, `P12_PASSWORD`,
   `BUILD_PROVISION_PROFILE_BASE64`; un tag `v*` pubblica una Release.

Nell'app, durante l'avvio della VM la console del kernel compare in tempo reale nel log dello step
(gruppo «Avvio della VM Linux integrata») e in Impostazioni → VM Linux; se la console resta muta per
4 minuti l'avvio viene interrotto con le ultime righe ricevute.

Gli unit test (`Tests/ActionsRunnerTests`) non fanno parte della CI; si eseguono da Xcode (⌘U).

### Compatibilità con i workflow per Ubuntu

Nella VM sono presenti `sudo` (esegue direttamente il comando: si è già root), `apt-get`/`apt`
(traducono `install`/`update` in `apk`, con i nomi dei pacchetti più comuni convertiti) e `brew`
(installa con `apk` o spiega l'alternativa).

### In locale su un Mac

```bash
brew install xcodegen
./scripts/build-linux-image.sh            # richiede Docker
mkdir -p Sources/ActionsRunner/Resources/LinuxVM && cp out/* Sources/ActionsRunner/Resources/LinuxVM/
./scripts/build-tinyemu.sh
xcodegen generate
xcodebuild -project ActionsRunner.xcodeproj -scheme ActionsRunner -sdk iphoneos \
  OTHER_LDFLAGS="-Wl,-force_load,$PWD/Vendor/LinuxVM/libtemu.a -lresolv -lz" build
```

## Struttura

```
project.yml                     XcodeGen (nessun pacchetto esterno)
.github/workflows/build.yml     CI: immagine Linux, emulatore, test, IPA
scripts/
  build-linux-image.sh          kernel + bbl + rootfs Alpine riscv64 (ext2)
  linux-rootfs.sh               creazione del rootfs (eseguito in un container Alpine)
  build-tinyemu.sh              TinyEMU → libtemu.a per iOS (+ verifica di collegamento)
  tinyemu-ios/                  adattamenti per il sorgente originale di TinyEMU
  test-vm-boot.sh, vm-boot-test.py  collaudo dell'avvio della VM sul runner Linux
  vm/ar-init, vm/ar-agent       init e agente della VM (protocollo sulla console)
  vm/cmdline.txt                riga di comando del kernel (unica per app e collaudo)
  vm/compat/                    sudo, apt-get/apt, brew per i workflow scritti per Ubuntu
Sources/ActionsRunner/
  Core/        JSONValue ordinato, parser YAML
  Workflow/    modello e validazione dei workflow
  Expressions/ espressioni ${{ }}
  Engine/      runner, matrix, comandi di workflow, azioni
  Shell/       interprete bash integrato
  VM/          bridge C verso TinyEMU e gestione della VM
  GitHub/      API REST, caricamento (Git Data API), avvio e monitoraggio delle run, sealed box
  Storage/     progetti, impostazioni, ZIP
  Views/       interfaccia (progetti, esecuzioni, terminale Linux, impostazioni)
Tests/ActionsRunnerTests/       test (Xcode) di YAML, ZIP, espressioni, matrix, shell, integrazione
```

## Licenze di terze parti incluse nella build

- TinyEMU © Fabrice Bellard, port macOS/iOS di Fernando Lemos — licenza MIT (slirp: licenza BSD).
- Kernel Linux (GPLv2) e pacchetti Alpine Linux (licenze dei rispettivi progetti) nell'immagine della VM.

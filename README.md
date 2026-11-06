# Actions Runner per iOS

App iOS (SwiftUI, iOS 17+) che importa un **file .zip contenente una repository**, legge i workflow in
`.github/workflows/*.yml` e **li esegue interamente sul dispositivo**, come farebbe GitHub Actions:
nessun account, nessun token, nessun server, nessuna libreria di terze parti.

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

## Limiti onesti

- **Prestazioni**: la VM è un emulatore interpretato (iOS non permette JIT alle app normali).
  L'avvio richiede da decine di secondi ad alcuni minuti e i comandi pesanti (es. `npm install`,
  compilazioni C) sono molto più lenti che su un PC.
- **Niente Xcode/macOS**: un job `runs-on: macos-*` gira comunque nella VM Linux, quindi `xcodebuild`,
  `swift`, `codesign` non esistono (non esistono per Linux/iOS). I container Docker non sono eseguibili.
- La VM ha la memoria limitata dalle regole di iOS (impostabile, predefinita 512 MB).
- Kernel della VM: Linux 4.15 riscv64 dell'immagine ufficiale di TinyEMU; alcuni programmi molto recenti
  potrebbero richiedere un kernel più nuovo.

## Costruire l'app (GitHub Actions)

1. Carica questa repository su GitHub.
2. Il workflow `.github/workflows/build.yml` ha due job:
   - **linux-image** (Ubuntu): scarica kernel e firmware di TinyEMU e crea il rootfs Alpine riscv64
     (`scripts/build-linux-image.sh`; pacchetti personalizzabili con l'input `alpine_packages`);
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
  vm/ar-init, vm/ar-agent       init e agente della VM (protocollo sulla console)
  vm/compat/                    sudo, apt-get/apt, brew per i workflow scritti per Ubuntu
Sources/ActionsRunner/
  Core/        JSONValue ordinato, parser YAML
  Workflow/    modello e validazione dei workflow
  Expressions/ espressioni ${{ }}
  Engine/      runner, matrix, comandi di workflow, azioni
  Shell/       interprete bash integrato
  VM/          bridge C verso TinyEMU e gestione della VM
  Storage/     progetti, impostazioni, ZIP
  Views/       interfaccia (progetti, esecuzioni, terminale Linux, impostazioni)
Tests/ActionsRunnerTests/       test (Xcode) di YAML, ZIP, espressioni, matrix, shell, integrazione
```

## Licenze di terze parti incluse nella build

- TinyEMU © Fabrice Bellard, port macOS/iOS di Fernando Lemos — licenza MIT (slirp: licenza BSD).
- Kernel Linux (GPLv2) e pacchetti Alpine Linux (licenze dei rispettivi progetti) nell'immagine della VM.

# Actions Runner per iOS

App iOS (SwiftUI, iOS 17+) che importa un **file .zip contenente una repository**, legge i workflow in
`.github/workflows/*.yml` ed **esegue le GitHub Actions** per costruire il progetto contenuto.

L'app ha due motori di esecuzione:

| Modalità | Cosa fa | Fedeltà |
|---|---|---|
| **Esegui su GitHub** | Carica il contenuto dello zip in un repository (Git Data API, senza git sul telefono), avvia il workflow sui **runner ufficiali GitHub** (macOS con Xcode, Ubuntu, Windows), segue la run in tempo reale, mostra log, annotazioni e scarica gli artifact (es. l'IPA). | **Esatta e letterale**: il workflow gira esattamente com'è scritto, sugli stessi runner di GitHub. |
| **Esegui sul dispositivo** | Motore Actions completo scritto in Swift: YAML, espressioni, contesti, matrix, needs, step, file d'ambiente, comandi di workflow, azioni composite, reusable workflow, interprete bash integrato. | Semantica identica per tutto ciò che iOS permette (vedi limiti). |

## Perché due modalità

iOS vieta `fork`/`exec`/`posix_spawn` alle app: **nessuna app iOS può avviare processi esterni** come
`bash`, `xcodebuild`, `node`, `docker` o `swift`. Inoltre Xcode e gli SDK di compilazione non esistono su iOS.
Per questo:

- la modalità **GitHub** è quella che costruisce davvero il progetto (incluso un IPA iOS) eseguendo
  *letteralmente* il tuo `build.yml` sui runner macOS di GitHub;
- la modalità **dispositivo** riproduce fedelmente il motore di GitHub Actions e un interprete bash
  con oltre 100 comandi reimplementati in Swift; gli step che richiedono toolchain di sistema falliscono
  con un messaggio chiaro che suggerisce l'esecuzione su GitHub.

## Funzionalità del motore locale

- **YAML 1.2 core schema** (come GitHub: `on`, `yes`, `no` restano stringhe), ancore e merge key.
- **Espressioni `${{ }}`**: letterali, operatori `! < <= > >= == != && ||` con le regole di uguaglianza *loose*
  e confronto case-insensitive, indicizzazione, filtri `*`, funzioni `contains`, `startsWith`, `endsWith`,
  `format`, `join`, `toJSON`, `fromJSON`, `hashFiles`, `case` (gen 2026), `success`, `failure`, `cancelled`, `always`;
  `if:` con `success()` implicito.
- **Contesti**: `github` (con payload evento per push / pull_request / workflow_dispatch / release), `env`, `vars`,
  `secrets`, `inputs` tipizzati, `job`, `jobs`, `steps`, `runner`, `strategy`, `matrix`, `needs`.
- **Job**: grafo `needs` con rilevamento cicli, `if` a livello di job, `outputs`, `strategy.matrix` con
  `include`/`exclude` secondo l'algoritmo documentato, `fail-fast`, `continue-on-error`, `timeout-minutes`,
  `defaults.run`, `env` a tutti i livelli, `runs-on` (determina `runner.os`/`RUNNER_OS`).
- **Step**: `run` (shell `bash`/`sh` con le stesse opzioni `-e`/`-eo pipefail` del runner), `working-directory`,
  `shell`, `env`, `if`, `continue-on-error`, `timeout-minutes`, `id`, nome valutato.
- **File d'ambiente**: `$GITHUB_OUTPUT`, `$GITHUB_ENV`, `$GITHUB_PATH`, `$GITHUB_STEP_SUMMARY`, `$GITHUB_STATE`
  (anche multilinea `name<<DELIM`).
- **Comandi di workflow**: `::group::`, `::endgroup::`, `::error/warning/notice file=,line=,title=::`, `::debug::`,
  `::add-mask::`, `::set-output::` (deprecato), `::save-state::`, `::stop-commands::`, `::echo::`; formato legacy `##[...]`.
  Maschere automatiche dei secrets.
- **Azioni**: composite (locali `./...` e remote `owner/repo/path@ref`, scaricate via zipball e messe in cache),
  input con default e `INPUT_*`, output, `github.action_path`; emulazioni native di `actions/checkout`
  (anche di altri repository), `actions/upload-artifact`, `actions/download-artifact`, `actions/cache`
  (+ `restore`/`save` con post-step), setup di toolchain (`setup-node`, `setup-python`, `setup-xcode`…) emulati.
  Le azioni JavaScript/Docker possono fallire (fedele) o essere saltate (impostazione).
- **Reusable workflow** (`jobs.<id>.uses`) locali e remoti, con `with`, `secrets` / `secrets: inherit` e output.
- **Interprete bash**: pipeline, `&& ||`, `;`, subshell, gruppi, `if/elif/else`, `for`, `for ((;;))`, `while/until`,
  `case` (con `;&`/`;;&`), funzioni con `local`, heredoc (`<<`, `<<-`, quotati), here-string, redirezioni (`> >> < 2>&1 &>`),
  espansioni `${var:-}` `${#var}` `${var%%}` `${var//}` `${var:off:len}` `${var^^}`, `$(( ))`, `(( ))`, `[[ ]]` con `=~`,
  globbing, `set -euxo pipefail`, `trap EXIT`, script `./build.sh` e `bash -c`.
  Comandi: `echo printf cd pwd export unset set shift read source eval test [ ls mkdir rm cp mv touch ln chmod
  find cat head tail wc grep sed awk cut tr sort uniq tee basename dirname realpath date seq xargs uname base64
  sha256sum md5sum zip unzip curl wget jq git (emulato) mktemp sleep env …`.

## Requisiti del token GitHub (modalità GitHub)

- **Classic**: scope `repo` e `workflow` (necessario per caricare file in `.github/workflows`).
- **Fine-grained**: Contents, Actions, Workflows, Secrets, Variables in *Read and write*; Administration *Read and write*
  se vuoi che l'app crei i repository.

Il token viene salvato nel Portachiavi. I secrets locali possono essere sincronizzati sul repository: l'app li cifra
con `crypto_box_seal` (X25519 + XSalsa20-Poly1305, implementazione verificata con vettori di test) come richiesto
dall'API di GitHub.

Flusso: `GET /user` → crea il repo se manca (`auto_init`) → blob/tree/commit/ref → `workflow_dispatch` con
`return_run_details` (oppure trigger `push`) → polling di run e job → log (`/actions/jobs/{id}/logs`) e annotazioni
(`/check-runs/{id}/annotations`) → artifact (`archive_download_url`).

## Costruire l'app

### Con GitHub Actions (consigliato, nessun Mac necessario)

1. Crea un repository e carica questi file.
2. Il workflow `.github/workflows/build.yml` parte su push/PR o manualmente (*Run workflow*):
   - job **test**: genera il progetto con XcodeGen ed esegue gli unit test sul simulatore;
   - job **build**: archivia in Release **senza firma** e pubblica l'artifact `ActionsRunner-unsigned-ipa`.
3. Scarica l'IPA dagli artifact della run e installalo con AltStore, SideStore, Sideloadly o TrollStore
   (che firmano l'app con il tuo Apple ID).
4. Facoltativo – IPA firmato: aggiungi i secrets `BUILD_CERTIFICATE_BASE64`, `P12_PASSWORD`,
   `BUILD_PROVISION_PROFILE_BASE64` (e opzionalmente `KEYCHAIN_PASSWORD`, variabile `EXPORT_METHOD`).
5. Un tag `v*` crea automaticamente una Release con gli IPA allegati.

### In locale su un Mac

```bash
brew install xcodegen
xcodegen generate
open ActionsRunner.xcodeproj
```

Cambia `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml` se vuoi firmare con il tuo team.

## Struttura

```
project.yml                       Specifica XcodeGen (target app + unit test, pacchetti Yams e ZIPFoundation)
.github/workflows/build.yml       CI: test, IPA non firmato, firma opzionale, release
Sources/ActionsRunner/
  App/           Entry point, RunCenter (esecuzioni attive)
  Core/          JSONValue ordinato, loader YAML
  Workflow/      Modello workflow/job/step, parser e validatore
  Expressions/   Lexer, parser, valutatore e funzioni delle espressioni
  Engine/        Runner locale, matrix, grafo, comandi di workflow, azioni emulate
  Shell/         Interprete bash e comandi integrati
  GitHub/        Client REST, push via Git Data API, sessione cloud
  Crypto/        Sealed box (BLAKE2b, Salsa20/HSalsa20, Poly1305)
  Storage/       Progetti, impostazioni, Portachiavi, zip
  Views/         Interfaccia SwiftUI
Tests/ActionsRunnerTests/         Test di espressioni, matrix, parser, shell, crittografia, integrazione
```

## Limiti noti della modalità dispositivo

- Nessun processo esterno: `xcodebuild`, `swift`, `node`, `python`, `docker`, `brew`… non sono disponibili
  (per costruire davvero usa *Esegui su GitHub*).
- Azioni JavaScript (`runs.using: node20/node24`) e Docker non eseguibili; `container:`/`services:` ignorati.
- I job della matrix vengono eseguiti in sequenza; `concurrency` e le regole degli environment non sono applicate.
- `git` è emulato solo per `rev-parse`, `log`, `branch`, `status`; gli array bash non sono supportati.

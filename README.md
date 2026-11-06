# Actions Runner per iOS

App iOS (SwiftUI, iOS 17+) che importa un **file .zip contenente una repository** e ne esegue i workflow
(`.github/workflows/*.yml`) **sui runner reali di GitHub** (Ubuntu, Windows, **macOS con Xcode**),
mostrando nell'app job, step, log, annotazioni e artifact (es. l'IPA). Nessuna libreria di terze parti.

## Uso

1. **Impostazioni → Account GitHub**: incolla un token di accesso personale.
   - consigliato: token *classic* con scope `repo` e `workflow` (il link nell'app apre la pagina già compilata);
   - in alternativa *fine-grained* con Contents, Actions, Workflows, Secrets e Variables in lettura/scrittura
     (Administration in scrittura per creare repository dall'app).

   Il token resta nel portachiavi del dispositivo e viene inviato solo a `api.github.com`.
2. **Progetti → +**: importa lo zip (va bene anche il "Download ZIP" di GitHub).
3. Apri un workflow → **Esegui su GitHub** → scegli o crea un repository e il branch → **Avvia**.

## Cosa fa

- **Caricamento**: calcola in locale gli SHA-1 git dei file e carica solo quelli che GitHub non ha
  (Git Data API, 4 upload in parallelo, cache dei blob già inviati); crea un commit con l'albero
  identico al progetto (permessi eseguibili e symlink inclusi). La storia del branch non viene riscritta.
- **Avvio**: con `workflow_dispatch` (e i suoi input) se il workflow lo dichiara, altrimenti con il
  **push** del commit; l'ID della run arriva dalla risposta di GitHub (`return_run_details`) o viene
  cercato per commit.
- **Secrets e variabili**: facoltativamente copia nel repository quelli configurati nell'app; i secrets
  sono cifrati sul dispositivo con la *sealed box* di libsodium (reimplementata in Swift e verificata
  contro libsodium).
- **Monitoraggio**: richieste condizionali con ETag (le risposte 304 non consumano il limite di GitHub),
  intervallo adattivo (3 s in esecuzione, 5 s in coda, più lento se il limite si avvicina), ripresa
  automatica dopo errori di rete.
- **Log**: scaricati per ogni job (anche parziali durante l'esecuzione), divisi per step tramite gli
  orari, con gruppi, errori e avvisi come su github.com; annotazioni dei job.
- **Artifact**: elenco, download, contenuto e condivisione dei singoli file (es. `.ipa`).
- **Controllo**: annulla (anche forzato), riesegui (tutti i job, solo i falliti, con log di debug),
  apri su GitHub.
- **Persistenza**: le run restano nella scheda Esecuzioni; dopo il riavvio dell'app il monitoraggio
  riprende; notifica di fine se l'app è in background.

## Costruire l'app (GitHub Actions)

1. Carica questa cartella in un repository GitHub (con `project.yml` e `.github/`).
2. Il workflow `.github/workflows/build.yml` (macOS 26) genera il progetto con XcodeGen, archivia l'app
   e produce l'**IPA non firmato** (artifact `ActionsRunner-unsigned-ipa`).
3. Installa l'IPA con AltStore, SideStore, Sideloadly o TrollStore.
4. Opzionale: IPA firmato con i secrets `BUILD_CERTIFICATE_BASE64`, `P12_PASSWORD`,
   `BUILD_PROVISION_PROFILE_BASE64`; un tag `v*` pubblica una Release.

Gli unit test (`Tests/ActionsRunnerTests`) non fanno parte della CI; si eseguono da Xcode (⌘U).

In locale su un Mac:

```bash
brew install xcodegen
xcodegen generate
open ActionsRunner.xcodeproj
```

## Struttura

```
project.yml                     XcodeGen (nessun pacchetto esterno)
.github/workflows/build.yml     CI: IPA non firmato (+ firmato e release opzionali)
Sources/ActionsRunner/
  App/         avvio dell'app, schede, RunCenter (run su GitHub)
  GitHub/      API REST, caricamento (Git Data API), avvio e monitoraggio delle run, sealed box
  Core/        JSON ordinato, parser YAML, modelli di stato
  Workflow/    lettura e validazione dei workflow, matrix, filtri branch
  Expressions/ verifica delle espressioni ${{ }} prima dell'invio
  Storage/     progetti importati, impostazioni, portachiavi, ZIP
  Views/       interfaccia SwiftUI
Tests/ActionsRunnerTests/       test (YAML, espressioni, matrix, ZIP, crittografia, API)
```

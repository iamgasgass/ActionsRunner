import Foundation
import Observation

/// Mutex asincrono FIFO: i comandi verso la VM sono eseguiti uno alla volta.
final class AsyncMutex {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let l = NSLock()

    func lock() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            l.lock()
            if !locked {
                locked = true
                l.unlock()
                c.resume()
            } else {
                waiters.append(c)
                l.unlock()
            }
        }
    }

    func unlock() {
        l.lock()
        if waiters.isEmpty {
            locked = false
            l.unlock()
        } else {
            let w = waiters.removeFirst()
            l.unlock()
            w.resume()
        }
    }
}

/// Macchina virtuale Linux (RISC-V 64, Alpine Linux) eseguita interamente dentro l'app tramite TinyEMU.
/// La console della VM è un canale testuale: l'host invia `__AR_RUN__ <id> <script>` e l'agente
/// nella VM esegue lo script e risponde con `__AR_DONE__ <id> <exit code>`.
/// La cartella Caches dell'app è condivisa con la VM via virtio-9p in /mnt/host.
@Observable
final class LinuxVM {
    static let shared = LinuxVM()

    enum State: Equatable {
        case unavailable(String)
        case stopped
        case booting
        case ready
        case failed(String)

        var label: String {
            switch self {
            case .unavailable(let r): return "Non disponibile: \(r)"
            case .stopped: return "Spenta"
            case .booting: return "Avvio in corso…"
            case .ready: return "Pronta"
            case .failed(let m): return "Errore: \(m)"
            }
        }
    }

    var state: State = .stopped
    var bootLog: [String] = []
    var has9p = false
    var hasNetwork = false
    var kernel = ""
    var bootSeconds: Double = 0

    @ObservationIgnored private var inFD: Int32 = -1
    @ObservationIgnored private var outFD: Int32 = -1
    @ObservationIgnored private let ioLock = NSLock()
    @ObservationIgnored private var current: (id: String, onLine: (String) -> Void, done: CheckedContinuation<Int32, Never>)?
    @ObservationIgnored private var pendingEmpty = 0
    @ObservationIgnored private let gate = AsyncMutex()
    @ObservationIgnored private var internalState: State = .stopped

    struct VMError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private init() {
        if let reason = LinuxVM.unavailabilityReason() {
            state = .unavailable(reason)
            internalState = .unavailable(reason)
        }
    }

    // MARK: Risorse

    static var resourceURLs: (bios: URL, kernel: URL, rootfs: URL)? {
        guard let b = Bundle.main.url(forResource: "bbl64", withExtension: "bin"),
              let k = Bundle.main.url(forResource: "kernel-riscv64", withExtension: "bin"),
              let r = Bundle.main.url(forResource: "rootfs", withExtension: "ext2") else { return nil }
        return (b, k, r)
    }

    static func unavailabilityReason() -> String? {
        if ar_vm_available() == 0 { return "emulatore non incluso in questa build" }
        if resourceURLs == nil { return "immagine Linux non inclusa in questa build" }
        return nil
    }

    var isSupported: Bool {
        if case .unavailable = internalState { return false }
        return true
    }

    var isReady: Bool { internalState == .ready }

    /// Radice condivisa con la VM (montata in /mnt/host).
    static var sharedRoot: URL { AppPaths.caches }

    /// Converte un percorso host nel percorso visto dalla VM.
    static func guestPath(_ host: String, jobRoot: String? = nil) -> String {
        var candidates: [(String, String)] = []
        if let jr = jobRoot {
            candidates.append((jr, "/home/runner"))
            candidates.append((URL(fileURLWithPath: jr).resolvingSymlinksInPath().path, "/home/runner"))
        }
        let root = sharedRoot.path
        candidates.append((root, "/mnt/host"))
        candidates.append((URL(fileURLWithPath: root).resolvingSymlinksInPath().path, "/mnt/host"))
        for (prefix, guest) in candidates where !prefix.isEmpty {
            if host == prefix { return guest }
            if host.hasPrefix(prefix + "/") { return guest + host.dropFirst(prefix.count) }
        }
        return host
    }

    /// Sostituisce tutti i percorsi host contenuti in un testo (script, variabili d'ambiente).
    static func translate(_ text: String, jobRoot: String?) -> String {
        var out = text
        var pairs: [(String, String)] = []
        if let jr = jobRoot {
            pairs.append((URL(fileURLWithPath: jr).resolvingSymlinksInPath().path, "/home/runner"))
            pairs.append((jr, "/home/runner"))
        }
        let root = sharedRoot.path
        pairs.append((URL(fileURLWithPath: root).resolvingSymlinksInPath().path, "/mnt/host"))
        pairs.append((root, "/mnt/host"))
        // prima i prefissi più lunghi
        for (prefix, guest) in pairs.sorted(by: { $0.0.count > $1.0.count }) where !prefix.isEmpty && out.contains(prefix) {
            out = out.replacingOccurrences(of: prefix, with: guest)
        }
        return out
    }

    // MARK: Avvio

    private func setState(_ s: State) {
        ioLock.lock()
        internalState = s
        ioLock.unlock()
        onMain { self.state = s }
    }

    private func appendBootLog(_ line: String) {
        onMain {
            self.bootLog.append(line)
            if self.bootLog.count > 3000 { self.bootLog.removeFirst(self.bootLog.count - 3000) }
        }
    }

    /// Avvia la VM (se non è già avviata) e attende che l'agente sia pronto.
    func boot(memoryMB: Int = 512, timeout: TimeInterval = 600) async throws {
        ioLock.lock()
        let s = internalState
        ioLock.unlock()
        switch s {
        case .ready: return
        case .unavailable(let r): throw VMError(message: "VM Linux non disponibile: \(r)")
        case .failed(let m): throw VMError(message: "La VM Linux si è arrestata (\(m)). Riavvia l'app per riprovare.")
        case .booting:
            try await waitReady(timeout: timeout)
            return
        case .stopped:
            break
        }
        guard let res = LinuxVM.resourceURLs else { throw VMError(message: "Immagine Linux mancante") }
        setState(.booting)
        let started = Date()

        // configurazione TinyEMU
        let dir = AppPaths.support.appendingPathComponent("vm", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cfg = dir.appendingPathComponent("riscv64.cfg")
        let shared = LinuxVM.sharedRoot.path
        let config = """
        {
            version: 1,
            machine: "riscv64",
            memory_size: \(memoryMB),
            bios: "\(res.bios.path)",
            kernel: "\(res.kernel.path)",
            cmdline: "console=hvc0 root=/dev/vda rw rootfstype=ext2 init=/sbin/ar-init quiet loglevel=3",
            drive0: { file: "\(res.rootfs.path)" },
            fs0: { tag: "hostfs", file: "\(shared)" },
            eth0: { driver: "user" },
        }
        """
        try config.write(to: cfg, atomically: true, encoding: .utf8)
        appendBootLog("Configurazione: \(cfg.path)")
        appendBootLog("RAM: \(memoryMB) MB · cartella condivisa: \(shared) → /mnt/host")

        var inW: Int32 = -1, outR: Int32 = -1
        let rc = cfg.path.withCString { ar_vm_start($0, &inW, &outR) }
        guard rc == 0 else {
            setState(.failed("avvio dell'emulatore non riuscito (\(rc))"))
            throw VMError(message: "Avvio dell'emulatore non riuscito (codice \(rc))")
        }
        inFD = inW
        outFD = outR
        startReader()
        try await waitReady(timeout: timeout)
        let elapsed = Date().timeIntervalSince(started)
        onMain { self.bootSeconds = elapsed }
        // preparazione dell'ambiente (python -> python3, cartelle)
        _ = try? await runCommandLine("[ -e /usr/bin/python ] || ln -s python3 /usr/bin/python 2>/dev/null; mkdir -p /home/runner; true", onLine: { _ in })
    }

    private func waitReady(timeout: TimeInterval) async throws {
        let limit = Date().addingTimeInterval(timeout)
        while true {
            ioLock.lock()
            let s = internalState
            ioLock.unlock()
            switch s {
            case .ready: return
            case .failed(let m): throw VMError(message: m)
            case .unavailable(let r): throw VMError(message: r)
            default: break
            }
            if Date() > limit { throw VMError(message: "La VM non ha completato l'avvio entro \(Int(timeout)) secondi") }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    // MARK: Lettura della console

    private func startReader() {
        let fd = outFD
        let thread = Thread { [weak self] in
            var pending = Data()
            var buf = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = read(fd, &buf, buf.count)
                if n <= 0 { break }
                pending.append(contentsOf: buf[0..<n])
                while let nl = pending.firstIndex(of: 0x0A) {
                    var lineData = pending[pending.startIndex..<nl]
                    if lineData.last == 0x0D { lineData = lineData.dropLast() }
                    pending.removeSubrange(pending.startIndex...nl)
                    self?.handleLine(String(decoding: lineData, as: UTF8.self))
                }
            }
            self?.handleExit("console chiusa")
        }
        thread.name = "LinuxVM.console"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    private func handleExit(_ reason: String) {
        setState(.failed(reason))
        ioLock.lock()
        let cur = current
        current = nil
        ioLock.unlock()
        cur?.done.resume(returning: 137)
    }

    private func handleLine(_ raw: String) {
        // rimuove sequenze di escape ANSI del kernel/console
        let line = raw.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)

        if line.hasPrefix("__AR_VM_EXIT__") { handleExit("l'emulatore è terminato (\(line))"); return }

        ioLock.lock()
        let booting = internalState == .booting
        let cur = current
        ioLock.unlock()

        if booting {
            if line.hasPrefix("__AR_BOOT__") {
                let flags = line.split(separator: " ")
                let ninep = flags.contains("9p=1"), net = flags.contains("net=1")
                let k = flags.first { $0.hasPrefix("kernel=") }.map { String($0.dropFirst(7)) } ?? ""
                onMain { self.has9p = ninep; self.hasNetwork = net; self.kernel = k }
            }
            appendBootLog(line)
            if line.hasPrefix("__AR_READY__") { setState(.ready) }
            return
        }

        guard let c = cur else {
            if !line.isEmpty { appendBootLog(line) }
            return
        }
        if line.hasPrefix("__AR_DONE__ \(c.id) ") {
            let code = Int32(line.split(separator: " ").last ?? "1") ?? 1
            // la riga vuota prima del marcatore è aggiunta dall'agente
            if pendingEmpty > 0 { pendingEmpty -= 1 }
            for _ in 0..<pendingEmpty { c.onLine("") }
            pendingEmpty = 0
            ioLock.lock()
            current = nil
            ioLock.unlock()
            c.done.resume(returning: code)
            return
        }
        if line.isEmpty { pendingEmpty += 1; return }
        for _ in 0..<pendingEmpty { c.onLine("") }
        pendingEmpty = 0
        c.onLine(line)
    }

    private func send(_ text: String) {
        guard inFD >= 0 else { return }
        let data = Array(text.utf8)
        var off = 0
        while off < data.count {
            let n = data[off...].withUnsafeBufferPointer { write(inFD, $0.baseAddress, $0.count) }
            if n <= 0 { break }
            off += n
        }
    }

    /// Interrompe il comando in esecuzione (Ctrl-C sul terminale della VM).
    func interrupt() { send("\u{03}") }

    // MARK: Esecuzione

    /// Esegue uno script (percorso host, dentro la cartella condivisa) nella VM.
    func run(hostScript: URL, jobRoot: String?, deadline: Date?, isCancelled: @escaping () -> Bool,
             onLine: @escaping (String) -> Void) async throws -> Int32 {
        let guest = LinuxVM.guestPath(hostScript.path, jobRoot: nil)
        guard guest.hasPrefix("/mnt/host/") else { throw VMError(message: "Lo script non è nella cartella condivisa con la VM") }
        await gate.lock()
        defer { gate.unlock() }
        guard isReady else { throw VMError(message: "La VM non è pronta") }
        let id = UUID().uuidString.prefix(12).lowercased()

        // watchdog per timeout / annullamento
        let watchdog = Task.detached { [weak self] in
            var interrupted = false
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                let expired = deadline.map { Date() > $0 } ?? false
                if (expired || isCancelled()) && !interrupted {
                    interrupted = true
                    self?.interrupt()
                }
            }
        }
        defer { watchdog.cancel() }

        return await withCheckedContinuation { (c: CheckedContinuation<Int32, Never>) in
            ioLock.lock()
            current = (id: String(id), onLine: onLine, done: c)
            pendingEmpty = 0
            ioLock.unlock()
            send("__AR_RUN__ \(id) \(guest)\n")
        }
    }

    /// Esegue una riga di comando (scritta in uno script temporaneo condiviso).
    @discardableResult
    func runCommandLine(_ command: String, onLine: @escaping (String) -> Void) async throws -> Int32 {
        let dir = LinuxVM.sharedRoot.appendingPathComponent("vm-scripts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent("cmd-\(UUID().uuidString).sh")
        try ("#!/bin/sh\n" + command + "\n").write(to: f, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: f) }
        return try await run(hostScript: f, jobRoot: nil, deadline: nil, isCancelled: { false }, onLine: onLine)
    }

    /// Quotatura per sh: 'testo' con gli apici interni gestiti.
    static func shQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

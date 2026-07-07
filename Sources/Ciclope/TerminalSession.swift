import AppKit
import SwiftTerm

// Una sesión de terminal autocontenida: vista SwiftTerm + shell zsh + integración
// de eventos + buffer de output. Guarda su propia memoria (historial, cwd) para
// que Ghost pueda mudarse entre sesiones llevándose el contexto.
// Datos para resucitar una sesión cerrada: cwd, memoria de Ghost y log de output.
struct SessionRestoreInfo {
    let id: String
    let cwd: String?
    let history: [(cmd: String, exit: Int)]
    let customName: String?
    var chat: [(q: String, a: String)] = []
    var running: String? = nil
}

final class TerminalSession: NSObject, LocalProcessTerminalViewDelegate {
    let view: CiclopeTerminalView
    let id: String
    let logURL: URL
    private var logHandle: FileHandle?
    private let shell = ShellIntegration()
    private var outputBuffer = Data()
    private var lastCmd: String?

    static var sessionsDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ciclope/sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    weak var brain: Brain?
    var onTitleChange: ((String) -> Void)?
    var onExited: ((TerminalSession) -> Void)?
    var onActivity: (() -> Void)?
    private(set) var title = "zsh"

    /// Nombre puesto por el usuario (doble click en la pestaña); si no, el cwd.
    var customName: String?
    private(set) var lastCommand: String?

    // Memoria de la sesión (Ghost se la lleva al migrar)
    var history: [(cmd: String, exit: Int)] = []
    /// Conversación con boo (pregunta, respuesta), para que no pierda el hilo.
    var chat: [(q: String, a: String)] = []
    /// Foto de la salida del último comando real (no boo): lo que boo "ve".
    private(set) var lastOutputSnapshot = ""
    /// Comando en ejecución ahora mismo (exec recibido sin done todavía).
    private(set) var runningCommand: String?
    /// Comando reanudable pendiente (claude --continue) tras una restauración.
    private(set) var pendingResume: String?
    private var resumeScheduled = false
    private static var resumeStagger = 0
    var commandCount = 0
    var lastSummaryCount = 0
    var lastSummaryTime = Date.distantPast
    private(set) var currentDirectory: String?

    /// Fichero donde el shell vuelca su entorno exportado en cada prompt.
    var stateURL: URL { shell.stateURL }

    var displayName: String {
        if let customName, !customName.isEmpty { return customName }
        let last = (title as NSString).lastPathComponent
        return last.isEmpty ? title : last
    }

    var subtitle: String {
        if let lastCommand, !lastCommand.isEmpty { return "❯ " + lastCommand }
        return title
    }

    /// Escribe texto en el shell como si lo tecleara el usuario.
    func send(_ text: String) {
        view.send(txt: text)
    }

    /// Pregunta a boo sobre un texto seleccionado en el terminal.
    func askBoo(about text: String) {
        let prompt = Prefs.language == "en" ? "explain this from my terminal: " : "explícame esto de mi terminal: "
        brain?.ask(self, prompt + text)
    }

    /// Cierra el shell de verdad: zsh interactivo ignora SIGTERM, hay que colgarle (SIGHUP).
    func terminate() {
        onExited = nil
        if let pid = view.process?.shellPid, pid > 0 {
            kill(pid, SIGHUP)
        }
        view.terminate()
    }

    // Banner de bienvenida (solo ventanas nuevas, no restauraciones ni splits).
    // Blanco puro (97m) sobre el tema que sea, estilo Ghost.
    private static var banner: String {
        let w = "\u{1B}[97m"   // blanco brillante
        let d = "\u{1B}[2m"    // atenuado
        let r = "\u{1B}[0m"    // reset
        let art = [
            #"   ▄██████▄     ▄████▄  ██  ██  ▄████▄  ▄████▄ ██████"#,
            #"  ██  ██████   ██       ██  ██ ██    ██ ██        ██"#,
            #"  ██████████   ██  ▄▄▄  ██████ ██    ██ ▀████▄    ██"#,
            #"  ██████████   ██   ██  ██  ██ ██    ██     ██    ██"#,
            #"  ▀▀█▀▀█▀▀█▀    ▀███▀   ██  ██  ▀████▀  ▀████▀    ██"#,
        ]
        var lines = [""]
        lines += art.map { w + $0 + r }
        lines += [
            "",
            "  \(d)" + L.t("banner.tagline") + r,
            "  \(d)" + L.t("banner.license") + r,
            "",
            "",
        ]
        return lines.joined(separator: "\r\n")
    }

    init(fontSize: CGFloat, restore: SessionRestoreInfo? = nil, banner: Bool = false) {
        view = CiclopeTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        id = restore?.id ?? UUID().uuidString
        logURL = Self.sessionsDir.appendingPathComponent("\(id).log")
        super.init()

        view.processDelegate = self
        view.session = self
        view.font = Theme.font(size: fontSize)
        view.nativeBackgroundColor = Theme.bg
        view.nativeForegroundColor = Theme.fg
        view.caretColor = Theme.accent
        view.installColors(Theme.ansi)
        view.getTerminal().setCursorStyle(.blinkBlock)
        view.changeScrollback(10000)

        // restaurar sesión anterior: memoria de Ghost + scrollback con colores.
        // El replay NO se hace aquí de golpe: 256KB de ANSI síncronos por sesión
        // clavaban la CPU y congelaban la app al arrancar. Se trocea más abajo.
        var replayData: [UInt8]? = nil
        if let restore {
            history = restore.history
            chat = restore.chat
            commandCount = history.count
            customName = restore.customName
            currentDirectory = restore.cwd
            if let data = try? Data(contentsOf: logURL), !data.isEmpty {
                replayData = [UInt8](data.suffix(98_304))
            }
        } else {
            try? FileManager.default.removeItem(at: logURL)
            if banner { view.feed(text: Self.banner) }
        }
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        logHandle = try? FileHandle(forWritingTo: logURL)
        _ = try? logHandle?.seekToEnd()

        view.onOutput = { [weak self] slice in
            guard let self else { return }
            self.outputBuffer.append(contentsOf: slice)
            if self.outputBuffer.count > 16384 {
                self.outputBuffer.removeFirst(self.outputBuffer.count - 16384)
            }
            self.logHandle?.write(Data(slice))
        }
        shell.onExec = { [weak self] cmd in
            guard let self else { return }
            self.lastCmd = cmd
            self.runningCommand = cmd
            self.lastCommand = String(cmd.prefix(60))
            self.outputBuffer.removeAll(keepingCapacity: true)
            self.brain?.commandStarted(self, cmd)
            self.onActivity?()
        }
        shell.onDone = { [weak self] exit, cwd in
            guard let self, let cmd = self.lastCmd else { return }
            self.runningCommand = nil
            if let cwd { self.currentDirectory = cwd }
            // guardar lo que ha salido por pantalla (salvo del propio boo),
            // para que boo tenga visibilidad de la terminal al preguntarle
            if !cmd.hasPrefix("boo") && !cmd.hasPrefix("__ciclope") {
                self.lastOutputSnapshot = String(self.cleanOutputTail().suffix(8000))
            }
            self.history.append((cmd, exit))
            if self.history.count > 40 { self.history.removeFirst() }
            self.commandCount += 1
            self.brain?.commandFinished(self, cmd: cmd, exit: exit, outputTail: self.cleanOutputTail())
        }
        shell.onAsk = { [weak self] q in
            guard let self else { return }
            self.brain?.ask(self, q)
        }

        let fallback = FileManager.default.currentDirectoryPath
        var startDir = restore?.cwd ?? (fallback == "/" ? NSHomeDirectory() : fallback)
        if !FileManager.default.fileExists(atPath: startDir) { startDir = NSHomeDirectory() }
        pendingStartDir = startDir
        pendingReplay = replayData

        // Si la sesión murió con un programa reanudable en marcha (claude...),
        // se apunta como pendiente: NO se lanza aquí. Lanzar N claudes a la vez
        // al restaurar reventaba la CPU; se reanuda solo al hacerse visible.
        pendingResume = restore?.running.flatMap { Self.resumeCommand(for: $0) }

        // El replay y el shell se activan cuando la vista tiene su TAMAÑO REAL:
        // reproducir con el ancho inicial (400px) partía mal las líneas del
        // scrollback restaurado (se veía roto, sobre todo en splits).
        view.onReady = { [weak self] in self?.activate() }
        // fallback por si nunca llega layout (pestaña de fondo): activar igual
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.activate()
        }
    }

    private var pendingReplay: [UInt8]?
    private var pendingStartDir = ""
    private var activated = false

    /// Reproduce el scrollback (ya con el ancho real) y arranca el shell. Una vez.
    private func activate() {
        guard !activated else { return }
        activated = true
        view.onReady = nil

        let startShell: () -> Void = { [weak self] in
            guard let self else { return }
            self.view.startProcess(executable: "/bin/zsh", args: [],
                                   environment: self.shell.environment, execName: "-zsh",
                                   currentDirectory: self.pendingStartDir)
        }
        if let replayData = pendingReplay {
            pendingReplay = nil
            replayLog(replayData) { [weak self] in
                guard let self else { return }
                let sanitize = "\u{1B}[?1000l\u{1B}[?1002l\u{1B}[?1003l\u{1B}[?1006l\u{1B}[?1015l"
                    + "\u{1B}[?1004l\u{1B}[?2004l\u{1B}[?1049l\u{1B}[?25h\u{1B}>\u{1B}[0m"
                self.view.feed(text: sanitize + "\u{1B}[999;1H\r\n\u{1B}[2m" + L.t("restored") + "\u{1B}[0m\r\n")
                startShell()
            }
        } else {
            startShell()
        }
    }

    /// Reproduce el log en chunks de 16KB espaciados para no bloquear el main thread.
    private func replayLog(_ data: [UInt8], completion: @escaping () -> Void) {
        let chunkSize = 16_384
        var chunks: [[UInt8]] = []
        var i = 0
        while i < data.count {
            chunks.append(Array(data[i..<min(i + chunkSize, data.count)]))
            i += chunkSize
        }
        guard !chunks.isEmpty else { completion(); return }
        for (n, chunk) in chunks.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(n) * 0.03) { [weak self] in
                self?.view.feed(byteArray: chunk[...])
                if n == chunks.count - 1 { completion() }
            }
        }
    }

    /// Reanuda el programa pendiente si la sesión está a la vista (pestaña
    /// activa o panel visible). Escalonado para no arrancar varios a la vez.
    func resumeIfPending() {
        guard pendingResume != nil, !resumeScheduled else { return }
        resumeScheduled = true
        let delay = 2.5 + Double(Self.resumeStagger) * 3.0
        Self.resumeStagger += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.resumeScheduled = false
            Self.resumeStagger = max(0, Self.resumeStagger - 1)
            guard let cmd = self.pendingResume,
                  self.view.superview != nil,
                  self.view.window?.isVisible == true,
                  !self.view.isHiddenOrHasHiddenAncestor else { return }
            self.pendingResume = nil
            self.send(cmd + "\n")
        }
    }

    /// Comandos que saben retomar su estado tras un cierre abrupto.
    static func resumeCommand(for cmd: String) -> String? {
        let first = cmd.split(separator: " ").first.map(String.init) ?? cmd
        switch first {
        case "claude": return "claude --continue"
        default: return nil
        }
    }

    deinit {
        try? logHandle?.close()
    }

    // MARK: - Persistencia

    /// Estado serializable de la sesión (para restaurar al reabrir la app).
    func snapshot() -> [String: Any] {
        compactLogIfNeeded()
        return [
            "id": id,
            "cwd": currentDirectory ?? "",
            "name": customName ?? "",
            "history": history.suffix(30).map { [$0.cmd, $0.exit] as [Any] },
            "chat": chat.suffix(8).map { [$0.q, $0.a] },
            "running": runningCommand ?? "",
        ]
    }

    static func restoreInfo(from dict: [String: Any]) -> SessionRestoreInfo? {
        guard let id = dict["id"] as? String else { return nil }
        let cwd = (dict["cwd"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let name = (dict["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        var history: [(cmd: String, exit: Int)] = []
        for entry in (dict["history"] as? [[Any]]) ?? [] {
            if let cmd = entry.first as? String, let exit = entry.last as? Int {
                history.append((cmd, exit))
            }
        }
        var chat: [(q: String, a: String)] = []
        for entry in (dict["chat"] as? [[String]]) ?? [] {
            if entry.count == 2 { chat.append((entry[0], entry[1])) }
        }
        let running = (dict["running"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return SessionRestoreInfo(id: id, cwd: cwd, history: history, customName: name,
                                  chat: chat, running: running)
    }

    /// Mantiene el log de output a raya (recorta al último cuarto de mega).
    private func compactLogIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path),
              let size = attrs[.size] as? Int, size > 400_000,
              let data = try? Data(contentsOf: logURL) else { return }
        try? logHandle?.close()
        try? data.suffix(262_144).write(to: logURL)
        logHandle = try? FileHandle(forWritingTo: logURL)
        _ = try? logHandle?.seekToEnd()
    }

    func setFontSize(_ size: CGFloat) {
        view.font = Theme.font(size: size)
    }

    /// Re-aplica los colores del tema activo al terminal.
    func applyTheme() {
        view.nativeBackgroundColor = Theme.bg
        view.nativeForegroundColor = Theme.fg
        view.caretColor = Theme.accent
        view.installColors(Theme.ansi)
        view.needsDisplay = true
    }

    func cleanOutputTail() -> String {
        guard let raw = String(data: outputBuffer, encoding: .utf8) else { return "" }
        var s = raw
        for pattern in [
            "\u{1B}\\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\\\)",
            "\u{1B}\\[[0-9;?]*[ -/]*[@-~]",
            "\u{1B}[@-_]",
        ] {
            s = s.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return s.replacingOccurrences(of: "\r", with: "")
    }

    // MARK: - LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        guard !title.isEmpty else { return }
        self.title = title
        onTitleChange?(title)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let directory, let url = URL(string: directory) else { return }
        let path = url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        title = path
        onTitleChange?(path)
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        onExited?(self)
    }
}

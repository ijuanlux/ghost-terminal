import Foundation

// El cerebro de Ghost: vive en UNA terminal concreta (attached), comenta lo que
// pasa en ella, resume periódicamente, responde al comando `ghost` y se muda de
// terminal llevándose la memoria de la sesión.
final class Brain {
    weak var cyclops: CyclopsView?
    weak var bubble: BubbleView?
    weak var commandBubble: BubbleView?
    private(set) weak var attached: TerminalSession?

    private var lastActivity = Date()
    private var idleWarned = false
    private var idleTimer: Timer?
    private var summaryTimer: Timer?
    private var spookyTimer: Timer?
    private var lastSpooky = Date()
    private var faceResetTimer: Timer?
    private var greeted = false

    private var isEN: Bool { Prefs.language == "en" }

    private var persona: String {
        isEN
        ? """
        You are Ghost, a pixel ghost that lives inside Juan's terminal and comments on what he does. \
        You speak casual buddy English, witty but not overdone; sometimes you drop a ghostly joke \
        (boo, haunting, the afterlife) without it being the only gag. You ALWAYS answer with a single \
        short sentence (max 18 words). No emojis, no quotes, no dashes, no lists.
        """
        : """
        Eres Ghost, un fantasmita pixel que vive dentro del terminal de Juan y comenta lo que hace. \
        Hablas español coloquial de colega, con gracia pero sin pasarte; a veces sueltas alguna coña \
        fantasmal (buu, aparecerse, el más allá) sin que sea el chiste único. Respondes SIEMPRE con una \
        sola frase corta (máximo 18 palabras). Sin emojis, sin comillas, sin guiones largos, sin listas.
        """
    }

    /// Elige una frase del idioma activo.
    private func pickL(_ es: [String], _ en: [String]) -> String {
        (isEN ? en : es).randomElement()!
    }

    /// Separa la prosa de los comandos entre backticks.
    private static func splitCommands(_ text: String) -> (prose: String, commands: [String]) {
        var commands: [String] = []
        var prose = ""
        var current = ""
        var inside = false
        for ch in text {
            if ch == "`" {
                if inside {
                    let cmd = current.trimmingCharacters(in: .whitespaces)
                    if !cmd.isEmpty { commands.append(cmd) }
                    prose += current   // la frase conserva el comando y se lee entera
                }
                current = ""
                inside.toggle()
            } else if inside {
                current.append(ch)
            } else {
                prose.append(ch)
            }
        }
        if inside { prose += current }   // backtick sin cerrar
        prose = prose.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (prose, commands)
    }

    /// Respuesta del LLM: si trae comandos, van en su propio bocadillo destacado.
    private func sayLLMReply(_ reply: String, holdFor: TimeInterval) {
        let (prose, commands) = Self.splitCommands(reply)
        DispatchQueue.main.async { [weak self] in
            guard let self, let bubble = self.bubble else { return }
            if !commands.isEmpty, let cb = self.commandBubble {
                cb.anchor = self.cyclops
                cb.say(commands.joined(separator: "\n"), holdFor: holdFor + 10)
                bubble.anchor = cb
                let text = prose.isEmpty ? self.llmTag.trimmingCharacters(in: .whitespacesAndNewlines) : prose + self.llmTag
                bubble.say(text, holdFor: holdFor)
            } else {
                bubble.anchor = self.cyclops
                self.commandBubble?.dismiss()
                bubble.say(reply + self.llmTag, holdFor: holdFor)
            }
        }
    }

    /// Extrae el primer bloque ```...``` (script) del texto; devuelve el resto.
    private static func extractScript(_ text: String) -> (rest: String, script: String?) {
        guard let start = text.range(of: "```") else { return (text, nil) }
        let afterStart = text[start.upperBound...]
        guard let end = afterStart.range(of: "```") else { return (text, nil) }
        var script = String(afterStart[..<end.lowerBound])
        if let nl = script.firstIndex(of: "\n") {
            let lang = script[..<nl].trimmingCharacters(in: .whitespaces).lowercased()
            if ["zsh", "bash", "sh", "shell", ""].contains(lang) {
                script = String(script[script.index(after: nl)...])
            }
        }
        script = script.trimmingCharacters(in: .whitespacesAndNewlines)
        let rest = (String(text[..<start.lowerBound]) + " " + String(afterStart[end.upperBound...]))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (rest, script.isEmpty ? nil : script)
    }

    /// Un script solo se auto-ejecuta si no borra ni toca nada delicado.
    private func scriptIsSafe(_ script: String) -> Bool {
        let forbidden = [
            #"(^|[;&|`$(\s])rm\s"#,
            #"\bsudo\b"#, #"\bmkfs\b"#, #"\bdiskutil\b"#, #"(^|\s)dd\s"#,
            #">\s*/dev/"#, #"curl.*\|\s*(z|ba)?sh"#, #"\bkillall\b"#,
            #"chmod\s+-R"#, #"\bshred\b"#, #"--delete"#,
        ]
        for pattern in forbidden {
            if script.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil {
                return false
            }
        }
        for line in script.split(separator: "\n") {
            if dangerCheck(String(line)) != nil { return false }
        }
        return true
    }

    /// Guarda el script y lo lanza en el terminal de la sesión, a la vista.
    private func runAction(_ script: String, on s: TerminalSession) {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ciclope", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("boo-action.zsh")
        let full = "#!/bin/zsh\n# generado por boo\nset -e\n" + script + "\n"
        try? full.write(to: url, atomically: true, encoding: .utf8)
        DispatchQueue.main.async {
            s.send("zsh '" + url.path + "'\n")
        }
    }

    /// Firma discreta con el modelo: distingue respuesta del LLM de frase enlatada.
    private var llmTag: String {
        guard let m = LMStudio.shared.modelName else { return "" }
        let short = m.split(separator: "-").prefix(2).joined(separator: "-")
        return "\n· \(short)"
    }

    init() {
        idleTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.checkIdle()
        }
        // sustos absurdos: de vez en cuando (media ~10 min, nunca antes de 8)
        spookyTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self,
                  self.cyclops?.face == .normal,
                  Date().timeIntervalSince(self.lastActivity) < 1800,
                  Date().timeIntervalSince(self.lastSpooky) > 480,
                  Int.random(in: 0..<10) == 0 else { return }
            self.lastSpooky = Date()
            self.cyclops?.spook()
            self.say(self.pickL(Self.spookyES, Self.spookyEN), holdFor: 12)
        }
        // resumen periódico: cada 10 min si ha habido movimiento en su terminal
        summaryTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self, Prefs.aiSummaries, let s = self.attached else { return }
            if s.commandCount - s.lastSummaryCount >= 4,
               Date().timeIntervalSince(s.lastSummaryTime) > 600 {
                self.summarize(s)
            }
        }
    }

    deinit {
        idleTimer?.invalidate()
        summaryTimer?.invalidate()
        spookyTimer?.invalidate()
        faceResetTimer?.invalidate()
    }

    // Historias de terror absurdas de informático
    private static let spookyES = [
        "buu. una vez vi un rm -rf sin backup. aún oigo los gritos",
        "dicen que a las 3:33 los node_modules susurran",
        "conocí a un sysadmin que desplegaba los viernes. nadie volvió a verlo",
        "¿oyes eso? es un cron job olvidado en 2019. sigue corriendo",
        "en el más allá también hay código legacy. está escrito en Perl",
        "anoche un proceso zombie me pidió que lo matara. no pude, era el PID 1",
        "hay un directorio maldito llamado /tmp. nada de lo que entra sale entero",
        "un becario hizo force push al main. su espíritu aún resuelve conflictos",
        "los ficheros que borras sin papelera me visitan por las noches. saludos de tus fotos de 2018",
        "el localhost está embrujado. llames a la hora que llames, siempre hay alguien en casa",
        "una vez un certificado caducó en domingo. todavía se habla de ello en los cementerios",
        "¿sabes qué da más miedo que un fantasma? un excel compartido con permisos de edición",
    ]
    private static let spookyEN = [
        "boo. I once saw an rm -rf with no backup. I still hear the screams",
        "they say at 3:33 the node_modules whisper",
        "I knew a sysadmin who deployed on Fridays. no one ever saw him again",
        "hear that? a cron job forgotten in 2019. still running",
        "the afterlife has legacy code too. it is written in Perl",
        "last night a zombie process begged me to kill it. I could not, it was PID 1",
        "there is a cursed directory called /tmp. nothing that enters leaves whole",
        "an intern force pushed to main. his spirit still resolves conflicts",
        "the files you delete without a trash can visit me at night. your 2018 photos say hi",
        "localhost is haunted. whenever you call, someone is always home",
        "a certificate once expired on a Sunday. they still talk about it in graveyards",
        "you know what is scarier than a ghost? a shared excel with edit permissions",
    ]

    // MARK: - Dónde vive Ghost

    /// Ghost se muda a una sesión. Si viene de otra, se lleva la memoria.
    func attach(_ s: TerminalSession, migrateFrom old: TerminalSession? = nil, announce: Bool = true) {
        guard attached !== s else { return }
        if let old, old !== s {
            s.history = Array((old.history + s.history).suffix(40))
            s.chat = Array((old.chat + s.chat).suffix(8))
        }
        attached = s
        if announce {
            say(pickL(["me mudo a esta terminal", "buu, casa nueva", "aquí se está mejor, me quedo"],
                      ["moving into this terminal", "boo, new home", "nicer over here, staying"]))
        }
    }

    // MARK: - Eventos del shell (llegan de todas las sesiones, Ghost solo atiende la suya)

    func greet() {
        guard !greeted else { return }
        greeted = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.say(self?.pickL([
                "buu. qué pasa, jefe",
                "sistema en línea, a romper cosas",
                "me aparezco por aquí, tú a lo tuyo",
                "arrancamos, dale caña",
                "de vuelta del más allá, buenas",
            ], [
                "boo. hey boss",
                "system online, let's break stuff",
                "just haunting around, carry on",
                "up and running, go for it",
                "back from the afterlife, hi",
            ]) ?? "buu")
        }
    }

    func commandStarted(_ s: TerminalSession, _ cmd: String) {
        touch()
        guard s === attached else { return }
        if let warning = dangerCheck(cmd) {
            setFace(.error, for: 8)
            say(warning, holdFor: 8)
        }
    }

    func commandFinished(_ s: TerminalSession, cmd: String, exit: Int, outputTail: String) {
        touch()
        guard s === attached else { return }
        if exit != 0 {
            reactToError(s, cmd: cmd, exit: exit, outputTail: outputTail)
        } else {
            reactToSuccess(s, cmd: cmd)
        }
        if s.commandCount - s.lastSummaryCount >= 12 {
            summarize(s)
        }
    }

    /// Comando `ghost` desde el shell: sin pregunta resume, con pregunta responde
    /// con el contexto de esa terminal. Ghost se muda a la terminal que le llama.
    func ask(_ s: TerminalSession, _ q: String) {
        touch()
        if attached !== s { attach(s, announce: false) }
        let question = q.trimmingCharacters(in: .whitespacesAndNewlines)
        if question.isEmpty {
            summarize(s)
            return
        }
        if ["olvida", "forget", "reset"].contains(question.lowercased()) {
            s.chat = []
            say(pickL(["borrón y cuenta nueva", "memoria limpia, como recién exorcizado"],
                      ["clean slate", "memory wiped, freshly exorcised"]))
            return
        }
        say(L.t("thinking"), holdFor: 90)
        setFace(.thinking, for: 90)
        LMStudio.shared.chat(
            system: persona,
            history: Array(s.chat.suffix(6)),
            user: context(for: s) + (isEN
                ? "\n\nJuan asks: \(question)\nAnswer helpfully and directly. If your answer includes a suggested command, wrap it in backticks like `this`. If Juan asks you to PERFORM an action (organize files, find and open a document, create folders...), reply with one short sentence plus a complete zsh script in a ```zsh fenced block```. Script rules: use mkdir -p, mv, cp, mdfind, open, ls; NEVER delete anything (no rm), move instead; use $HOME for paths. Reply in the same language the question is written in."
                : "\n\nPregunta de Juan: \(question)\nRespóndele útil y directo. Si sugieres un comando, escríbelo entre backticks `así`. Si Juan te pide REALIZAR una acción (organizar ficheros, buscar y abrir un documento, crear carpetas...), responde con una frase corta más un script zsh completo en un bloque cercado ```zsh```. Reglas del script: usa mkdir -p, mv, cp, mdfind, open, ls; NUNCA borres nada (nada de rm), mueve en su lugar; usa $HOME en las rutas. Responde en el mismo idioma de la pregunta."),
            maxTokens: 550
        ) { [weak self] reply in
            self?.setFace(.normal, for: 0)
            if let reply {
                s.chat.append((question, reply))
                if s.chat.count > 8 { s.chat.removeFirst(s.chat.count - 8) }
                let (rest, script) = Self.extractScript(reply)
                if let script, let self {
                    if Prefs.booActions && self.scriptIsSafe(script) {
                        self.runAction(script, on: s)
                        let msg = rest.isEmpty
                            ? (self.isEN ? "on it, watch the terminal" : "voy, mira la terminal")
                            : rest
                        self.sayLLMReply(msg, holdFor: 12)
                    } else {
                        // script vetado o acciones apagadas: enseñar, no ejecutar
                        DispatchQueue.main.async {
                            self.commandBubble?.anchor = self.cyclops
                            self.commandBubble?.say(script, holdFor: 40)
                            self.bubble?.anchor = self.commandBubble
                            self.bubble?.say(self.isEN
                                ? "this one needs your hand, I will not run it myself"
                                : "esto pide tu mano, no lo ejecuto yo solo", holdFor: 16)
                        }
                    }
                } else {
                    self?.sayLLMReply(reply, holdFor: 16)
                }
            } else {
                let off = (self?.isEN ?? false) ? "LM Studio is off, turn it on and I will check" : "LM Studio está apagado, enciéndelo y te lo miro"
                self?.say(off, holdFor: 14)
            }
        }
    }

    /// Click en el fantasma: resumen bajo demanda de su terminal.
    func onDemandSummary() {
        touch()
        guard let s = attached, !s.history.isEmpty else {
            say(pickL(["aún no has hecho nada aquí", "esto está muy tranquilo", "escribe algo, no muerdo"],
                      ["you have not done anything here yet", "very quiet in here", "type something, I do not bite"]))
            return
        }
        summarize(s)
    }

    // MARK: - Reglas

    private func dangerCheck(_ cmd: String) -> String? {
        let dangers: [(pattern: String, es: String, en: String)] = [
            (#"rm\s+(-\w*\s+)*-\w*r\w*f|rm\s+-\w*f\w*r"#,
             "ojo, eso borra sin preguntar", "careful, that deletes without asking"),
            (#"sudo\s+rm"#,
             "sudo rm... valiente, espero que sepas lo que haces", "sudo rm... brave, hope you know what you are doing"),
            (#"git\s+push\s+.*(--force|-f)\b"#,
             "force push detectado, reza por tus compañeros", "force push detected, pray for your teammates"),
            (#"DROP\s+(TABLE|DATABASE)"#,
             "un DROP, así, sin anestesia", "a DROP, just like that, no anesthesia"),
            (#"mkfs|diskutil\s+erase"#,
             "eso formatea de verdad, no es un simulacro", "that formats for real, this is not a drill"),
            (#">\s*/dev/(disk|rdisk)"#,
             "escribir a disco crudo, qué puede salir mal", "writing to raw disk, what could go wrong"),
            (#"chmod\s+-R\s+777"#,
             "777 recursivo, la seguridad llorando en una esquina", "recursive 777, security crying in a corner"),
        ]
        for d in dangers {
            if cmd.range(of: d.pattern, options: [.regularExpression, .caseInsensitive]) != nil {
                return isEN ? d.en : d.es
            }
        }
        return nil
    }

    private func reactToError(_ s: TerminalSession, cmd: String, exit: Int, outputTail: String) {
        setFace(.error, for: 6)
        let canned = pickL([
            "eso ha petado, exit \(exit)",
            "exit \(exit), clásico",
            "uy, revisa eso",
            "código \(exit), no era por ahí",
            "ha muerto con exit \(exit)",
        ], [
            "that blew up, exit \(exit)",
            "exit \(exit), classic",
            "oops, check that",
            "code \(exit), not that way",
            "it died with exit \(exit)",
        ])
        let tail = String(outputTail.suffix(700))
        if tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            say(canned)
            return
        }
        say(canned)
        setFace(.thinking, for: 30)
        LMStudio.shared.chat(
            system: persona,
            user: isEN
                ? "The command `\(cmd)` failed with exit \(exit). Last output lines:\n\(tail)\n\nSay in one short sentence what happened and how to fix it."
                : "El comando `\(cmd)` ha fallado con exit \(exit). Últimas líneas del output:\n\(tail)\n\nDi en una frase corta qué ha pasado y cómo arreglarlo.",
            maxTokens: 70
        ) { [weak self] reply in
            self?.setFace(.error, for: 4)
            if let reply { self?.sayLLMReply(reply, holdFor: 12) }
        }
    }

    private func reactToSuccess(_ s: TerminalSession, cmd: String) {
        let c = cmd.trimmingCharacters(in: .whitespaces)
        var msg: String?

        if c.range(of: #"^git\s+push\b"#, options: .regularExpression) != nil {
            msg = pickL(["push fuera, código volando", "enviado al remoto, limpio", "push ok, qué profesional"],
                        ["push done, code flying", "sent to remote, clean", "push ok, so professional"])
        } else if c.range(of: #"^git\s+commit\b"#, options: .regularExpression) != nil {
            msg = pickL(["commit hecho", "otro commit pal saco"], ["commit done", "another one for the pile"])
        } else if c.range(of: #"docker\s+(compose\s+)?up|kubectl\s+apply|terraform\s+apply|swift\s+build|npm\s+run\s+build|make\b"#, options: .regularExpression) != nil {
            msg = pickL(["construido sin drama", "eso ha ido fino", "verde, me gusta"],
                        ["built without drama", "that went smooth", "green, I like it"])
        } else if s.history.suffix(6).count == 6 && s.history.suffix(6).allSatisfy({ $0.exit == 0 }) && s.commandCount % 6 == 0 {
            msg = pickL(["seis seguidos sin fallar, racha", "todo verde, qué gusto da verte así"],
                        ["six in a row without failing, streak", "all green, love to see it"])
        }

        if let msg {
            setFace(.party, for: 4)
            say(msg)
        }
    }

    private func checkIdle() {
        let idle = Date().timeIntervalSince(lastActivity)
        if idle > 300 && !idleWarned {
            idleWarned = true
            cyclops?.face = .sleepy
            say(pickL(["zzz", "me aburro aquí abajo", "¿sigues vivo?", "avísame cuando vuelvas"],
                      ["zzz", "getting bored down here", "you still alive?", "ping me when you are back"]))
        }
    }

    private func touch() {
        lastActivity = Date()
        if idleWarned {
            idleWarned = false
            cyclops?.face = .normal
        }
    }

    // MARK: - LLM

    private func context(for s: TerminalSession) -> String {
        let cmds = s.history.suffix(12).map { "\($0.cmd) (exit \($0.exit))" }.joined(separator: "\n")
        let cwd = s.currentDirectory ?? s.title
        let tail = String(s.lastOutputSnapshot.suffix(3500))
        var ctx = "Terminal de Juan, directorio: \(cwd)\nÚltimos comandos:\n\(cmds)"
        if !tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ctx += "\nSalida del último comando (lo que Juan tiene en pantalla):\n\(tail)"
        }
        return ctx
    }

    private func summarize(_ s: TerminalSession) {
        guard !s.history.isEmpty else {
            say(pickL(["aquí no has hecho nada aún, buu", "terminal recién nacida, sin historia que contar", "tira algún comando y te cuento"],
                      ["nothing done here yet, boo", "newborn terminal, no story to tell", "run a command and I will fill you in"]))
            return
        }
        s.lastSummaryCount = s.commandCount
        s.lastSummaryTime = Date()
        setFace(.thinking, for: 30)
        LMStudio.shared.chat(
            system: persona,
            history: Array(s.chat.suffix(6)),
            user: context(for: s) + (isEN
                ? "\n\nSummarize in one short witty sentence what Juan is doing in this terminal."
                : "\n\nResume en una frase corta y con gracia qué está haciendo Juan en esta terminal."),
            maxTokens: 60
        ) { [weak self] reply in
            guard let self else { return }
            self.setFace(.normal, for: 0)
            if let reply {
                self.say(reply + self.llmTag, holdFor: 9)
            } else {
                let last = s.history.last!
                self.say(self.isEN
                    ? "you are \(s.commandCount) commands in here, last one: \(String(last.cmd.prefix(40)))"
                    : "llevas \(s.commandCount) comandos aquí, el último: \(String(last.cmd.prefix(40)))")
            }
        }
    }

    // MARK: - Helpers

    private func say(_ text: String, holdFor: TimeInterval? = nil) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.bubble?.anchor = self.cyclops
            self.commandBubble?.dismiss()
            self.bubble?.say(text, holdFor: holdFor)
        }
    }

    private func setFace(_ f: CyclopsView.Face, for seconds: TimeInterval) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.faceResetTimer?.invalidate()
            self.cyclops?.face = f
            if seconds > 0 {
                self.faceResetTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
                    self?.cyclops?.face = .normal
                }
            }
        }
    }

    private static func pick(_ options: [String]) -> String {
        options.randomElement()!
    }
}

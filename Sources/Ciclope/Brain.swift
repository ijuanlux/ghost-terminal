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

    /// Nombre de pila del usuario del Mac (boo no conoce a nadie de fábrica).
    private var userName: String {
        let full = NSFullUserName()
        let first = full.split(separator: " ").first.map(String.init) ?? full
        return first.isEmpty ? NSUserName() : first
    }

    private var persona: String {
        isEN
        ? """
        You are Ghost, a pixel ghost that lives inside \(userName)'s terminal and comments on what they do. \
        You speak casual buddy English, witty but not overdone; sometimes you drop a ghostly joke \
        (boo, haunting, the afterlife) without it being the only gag. You ALWAYS answer with a single \
        short sentence (max 18 words). No emojis, no quotes, no dashes, no lists.
        """
        : """
        Eres Ghost, un fantasmita pixel que vive dentro del terminal de \(userName) y comenta lo que hace. \
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
    private static func extractFenced(_ text: String) -> (rest: String, lang: String, body: String?) {
        guard let start = text.range(of: "```") else { return (text, "", nil) }
        let afterStart = text[start.upperBound...]
        guard let end = afterStart.range(of: "```") else { return (text, "", nil) }
        var body = String(afterStart[..<end.lowerBound])
        var lang = ""
        if let nl = body.firstIndex(of: "\n") {
            let first = body[..<nl].trimmingCharacters(in: .whitespaces).lowercased()
            if !first.isEmpty && !first.contains(" ") && first.count < 12 {
                lang = first
                body = String(body[body.index(after: nl)...])
            }
        }
        body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let rest = (String(text[..<start.lowerBound]) + " " + String(afterStart[end.upperBound...]))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (rest, lang, body.isEmpty ? nil : body)
    }

    /// Un comando de consulta silenciosa además no puede escribir nada.
    private func runIsSafe(_ cmd: String) -> Bool {
        guard scriptIsSafe(cmd) else { return false }
        let writes = #"[>]|\bmv\b|\bcp\b|\bmkdir\b|\btouch\b|\bchmod\b|\bchown\b|\bln\b|\bopen\b"#
        return cmd.range(of: writes, options: .regularExpression) == nil
    }

    /// Ejecuta un comando en silencio (fuera del terminal) y captura su salida.
    private static func execQuiet(_ cmd: String, completion: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
            proc.arguments = ["-c", cmd]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe
            var out = ""
            do {
                try proc.run()
                let killer = DispatchWorkItem { if proc.isRunning { proc.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 12, execute: killer)
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                killer.cancel()
                out = String(data: data, encoding: .utf8) ?? ""
            } catch {
                out = "error: \(error.localizedDescription)"
            }
            if out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out = "(sin salida)" }
            DispatchQueue.main.async { completion(out) }
        }
    }

    /// Enseña un script vetado en el bocadillo, sin ejecutarlo.
    private func showScriptForReview(_ script: String) {
        DispatchQueue.main.async {
            self.setFace(.normal, for: 0)
            self.commandBubble?.anchor = self.cyclops
            self.commandBubble?.say(script, holdFor: 40)
            self.bubble?.anchor = self.commandBubble
            self.bubble?.say(self.isEN
                ? "this one needs your hand, I will not run it myself"
                : "esto pide tu mano, no lo ejecuto yo solo", holdFor: 16)
        }
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

    /// Imprime contenido (tabla, resumen, listado, descripción) EN el terminal,
    /// tal cual, preservando formato: lo escribe a un fichero y hace cat.
    private func printToTerminal(_ text: String, on s: TerminalSession) {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ciclope", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("boo-print.txt")
        try? (text + "\n").write(to: url, atomically: true, encoding: .utf8)
        DispatchQueue.main.async {
            s.send("cat '" + url.path + "'\n")
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
        s.printStep(isEN ? "thinking..." : "pensando...")
        let instructions = isEN
            ? "\n\n\(userName) asks: \(question)\nYou HAVE REAL ACCESS to this Mac, never say you cannot access files. Mechanisms: (1) to LOOK SOMETHING UP (find files, list, info) reply ONLY with a ```run fenced block``` containing one read-only command (mdfind, find, ls, du, file, mdls...) and you will receive its output; to READ A DOCUMENT (pdf, docx, txt, md...) reply ONLY with a ```read fenced block``` containing just the file path and you will get its extracted text (NEVER cat a pdf/binary); (2) to SHOW content in the terminal (a table, a summary of a document, a long list, a description) reply with an optional short sentence plus a ```print fenced block``` whose content is dumped verbatim into the terminal (use plain text, aligned columns or markdown-ish tables); (3) to PERFORM a side-effecting action (open, move, organize, create) reply with one short sentence plus a ```zsh fenced block``` (mkdir -p, mv, cp, mdfind, open; NEVER delete, move instead; use $HOME). Short chat answers go in the bubble; use print for anything long or formatted. Reply in the language of the question."
            : "\n\nPregunta de \(userName): \(question)\nTIENES ACCESO REAL a este Mac, nunca digas que no puedes acceder a los ficheros. Mecanismos: (1) para CONSULTAR algo (buscar ficheros, listar, info) responde SOLO con un bloque cercado ```run``` con un comando de solo lectura (mdfind, find, ls, du, file, mdls...) y recibirás su salida; para LEER UN DOCUMENTO (pdf, docx, txt, md...) responde SOLO con un bloque ```read``` que contenga solo la ruta del fichero y recibirás su texto extraído (NUNCA hagas cat de un pdf/binario); (2) para MOSTRAR contenido en la terminal (una tabla, el resumen de un documento, un listado largo, una descripción) responde con una frase corta opcional más un bloque ```print``` cuyo contenido se vuelca tal cual en la terminal (texto plano, columnas alineadas o tablas estilo markdown); (3) para REALIZAR una acción con efectos (abrir, mover, organizar, crear) responde una frase corta más un bloque ```zsh``` (mkdir -p, mv, cp, mdfind, open; NUNCA borres, mueve en su lugar; usa $HOME). Las respuestas cortas de charla van en el bocadillo; usa print para lo largo o formateado. Responde en el idioma de la pregunta."
        hop(s, question: question, userMsg: context(for: s) + imageNote(s) + instructions,
            loopHist: [], hops: 0, image: s.pendingImage)
        s.pendingImage = nil
        s.pendingDocs = []
    }

    /// Un salto del bucle agéntico: el LLM puede pedir comandos de consulta
    /// (bloque run, ejecutados en silencio, salida de vuelta, máx 3 saltos)
    /// antes de responder o de lanzar una acción visible.
    /// Notas para el prompt: imagen adjunta y/o documentos que boo puede leer.
    private func imageNote(_ s: TerminalSession) -> String {
        var note = ""
        if s.pendingImage != nil {
            note += isEN
                ? "\n\n(An image is attached to this message; look at it to answer.)"
                : "\n\n(Hay una imagen adjunta a este mensaje; mírala para responder.)"
        }
        if !s.pendingDocs.isEmpty {
            let list = s.pendingDocs.joined(separator: ", ")
            note += isEN
                ? "\n\n(Attached documents you can read with a ```read``` block (one path per block): \(list))"
                : "\n\n(Documentos adjuntos que puedes leer con un bloque ```read``` (una ruta por bloque): \(list))"
        }
        return note
    }

    private func hop(_ s: TerminalSession, question: String, userMsg: String,
                     loopHist: [(q: String, a: String)], hops: Int, image: String? = nil) {
        LMStudio.shared.chat(
            system: persona,
            history: Array(s.chat.suffix(6)) + loopHist,
            user: userMsg,
            maxTokens: 600,
            imagePath: image
        ) { [weak self] reply in
            guard let self else { return }
            guard let reply else {
                self.setFace(.normal, for: 0)
                let off = self.isEN ? "LM Studio is off, turn it on and I will check" : "LM Studio está apagado, enciéndelo y te lo miro"
                self.say(off, holdFor: 14)
                return
            }
            let fenced = Self.extractFenced(reply)

            // tokens reales del modelo este salto (usage de LM Studio); si no
            // los reporta, estimación por caracteres como último recurso
            let t = LMStudio.shared.lastTokens
            Prefs.addBooTokens(t > 0 ? t : (userMsg.count + reply.count) / 4)

            // bloque read: extraer texto de un documento de forma NATIVA (PDFKit
            // etc.), sin cat de binarios. Rápido y limpio.
            if let body = fenced.body, fenced.lang == "read", hops < 3 {
                let path = body.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "\"", with: "")
                self.say(self.pickL(
                    ["leyendo los espíritus de este documento...",
                     "invocando lo que dice este papel...",
                     "escaneando el más allá del PDF..."],
                    ["reading the spirits of this document...",
                     "summoning what this paper says...",
                     "scanning the afterlife of this PDF..."]), holdFor: 60)
                self.setFace(.reading, for: 60)
                s.printStep((self.isEN ? "reading " : "leyendo ") + (path as NSString).lastPathComponent)
                DispatchQueue.global(qos: .userInitiated).async {
                    let text = DocReader.text(path) ?? "(no pude leer el documento)"
                    DispatchQueue.main.async {
                        let next = (self.isEN ? "Text of the document:\n" : "Texto del documento:\n")
                            + String(text.prefix(6000))
                            + (self.isEN
                                ? "\n\nNow answer the user. To show a summary/table in the terminal use ```print```."
                                : "\n\nAhora responde al usuario. Para mostrar un resumen/tabla en la terminal usa ```print```.")
                        self.hop(s, question: question, userMsg: next,
                                 loopHist: loopHist + [(userMsg, reply)], hops: hops + 1)
                    }
                }
                return
            }

            // bloque run: consultar la máquina en silencio y devolverle la salida
            if let body = fenced.body, fenced.lang == "run", hops < 3, Prefs.booActions {
                guard self.runIsSafe(body) else {
                    self.showScriptForReview(body)
                    return
                }
                self.say(self.isEN ? "let me look..." : "déjame mirar...", holdFor: 60)
                self.setFace(.thinking, for: 60)
                s.printStep((self.isEN ? "running: " : "ejecutando: ") + body.prefix(60))
                Self.execQuiet(body) { output in
                    let next = (self.isEN ? "Output of `\(body)`:\n" : "Salida de `\(body)`:\n")
                        + String(output.prefix(1800))
                        + (self.isEN
                            ? "\n\nContinue: answer the user, look up more with ```run```, read a document with ```read```, or act with ```zsh```."
                            : "\n\nContinúa: responde al usuario, consulta más con ```run```, lee un documento con ```read```, o actúa con ```zsh```.")
                    self.hop(s, question: question, userMsg: next,
                             loopHist: loopHist + [(userMsg, reply)], hops: hops + 1)
                }
                return
            }

            // respuesta final
            self.setFace(.normal, for: 0)
            s.printStep((self.isEN ? "done" : "listo") + "\r\n")
            Prefs.countBooQuery()
            s.chat.append((question, reply))
            if s.chat.count > 8 { s.chat.removeFirst(s.chat.count - 8) }

            // bloque print: volcar contenido formateado (tabla, resumen, listado,
            // descripción) EN el terminal, no en el bocadillo
            if let body = fenced.body, fenced.lang == "print" {
                self.printToTerminal(body, on: s)
                let msg = fenced.rest.isEmpty
                    ? (self.isEN ? "there you go, in the terminal" : "ahí lo tienes, en la terminal")
                    : fenced.rest
                self.sayLLMReply(msg, holdFor: 10)
            } else if let script = fenced.body {
                if Prefs.booActions && self.scriptIsSafe(script) {
                    self.runAction(script, on: s)
                    let msg = fenced.rest.isEmpty
                        ? (self.isEN ? "on it, watch the terminal" : "voy, mira la terminal")
                        : fenced.rest
                    self.sayLLMReply(msg, holdFor: 12)
                } else {
                    self.showScriptForReview(script)
                }
            } else {
                // respuesta de texto: si es larga (resumen, explicación), al
                // terminal aunque el modelo olvidara el bloque print; si es
                // corta, al bocadillo como siempre
                let clean = reply.trimmingCharacters(in: .whitespacesAndNewlines)
                if clean.count > 220 {
                    self.printToTerminal(clean, on: s)
                    self.sayLLMReply(self.isEN ? "there you go, in the terminal" : "ahí lo tienes, en la terminal",
                                     holdFor: 8)
                } else {
                    self.sayLLMReply(reply, holdFor: 16)
                }
            }
        }
    }

    /// Chip estilo Claude al soltar media en el terminal: [1 image · 2 documents].
    func confirmMedia(images: Int, docs: Int) {
        touch()
        var parts: [String] = []
        if images > 0 { parts.append("\(images) image" + (images == 1 ? "" : "s")) }
        if docs > 0 { parts.append("\(docs) document" + (docs == 1 ? "" : "s")) }
        let chip = "[" + parts.joined(separator: " · ") + "]"
        say(chip + (isEN ? "  ask me with boo" : "  pregúntame con boo"), holdFor: 12)
    }

    /// Imagen soltada sobre Ghost: queda adjunta para la próxima pregunta a boo.
    func attachImage(_ path: String) {
        touch()
        attached?.pendingImage = path
        let name = (path as NSString).lastPathComponent
        say(pickL(["imagen lista: \(name). pregúntame por ella con boo",
                   "ya la veo. dime qué quieres saber con boo"],
                  ["got the image: \(name). ask me about it with boo",
                   "I can see it. ask me anything with boo"]), holdFor: 10)
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
        var ctx = "Terminal de \(userName), directorio: \(cwd)\nÚltimos comandos:\n\(cmds)"
        if !tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ctx += "\nSalida del último comando (lo que \(userName) tiene en pantalla):\n\(tail)"
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
                ? "\n\nSummarize in one short witty sentence what \(userName) is doing in this terminal."
                : "\n\nResume en una frase corta y con gracia qué está haciendo \(userName) en esta terminal."),
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

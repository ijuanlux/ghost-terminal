import Foundation

// Integración con zsh vía ZDOTDIR: arrancamos el shell con un ZDOTDIR propio que
// primero carga la config del usuario y luego añade hooks preexec/precmd que
// escriben eventos JSON (comando en base64, exit code, cwd) a un fichero que la
// app va leyendo. También vuelca el entorno exportado en cada prompt (para poder
// migrar la sesión a otra terminal) y define el comando `ghost`.
final class ShellIntegration {
    let eventsURL: URL
    let stateURL: URL
    let zdotdir: URL
    private var offset: UInt64 = 0
    private var pollTimer: Timer?

    var onExec: ((String) -> Void)?
    var onDone: ((Int, String?) -> Void)?   // exit code, cwd
    var onAsk: ((String) -> Void)?          // comando `ghost <pregunta>`

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ciclope", isDirectory: true)
        zdotdir = support.appendingPathComponent("zdot", isDirectory: true)
        try? FileManager.default.createDirectory(at: zdotdir, withIntermediateDirectories: true)

        let id = UUID().uuidString
        eventsURL = FileManager.default.temporaryDirectory.appendingPathComponent("ciclope-\(id).jsonl")
        stateURL = FileManager.default.temporaryDirectory.appendingPathComponent("ciclope-state-\(id).env")
        FileManager.default.createFile(atPath: eventsURL.path, contents: nil)

        writeZdotFiles()
        startPolling()
    }

    deinit {
        pollTimer?.invalidate()
        try? FileManager.default.removeItem(at: eventsURL)
        try? FileManager.default.removeItem(at: stateURL)
    }

    var environment: [String] {
        var env: [String: String] = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["ZDOTDIR"] = zdotdir.path
        env["CICLOPE_EVENTS"] = eventsURL.path
        env["CICLOPE_STATE"] = stateURL.path
        env["TERM_PROGRAM"] = "Ghost"
        env.removeValue(forKey: "TERMINFO")
        return env.map { "\($0.key)=\($0.value)" }
    }

    private func writeZdotFiles() {
        let zshenv = """
        # Ghost: cargar el zshenv real del usuario
        [ -f "$HOME/.zshenv" ] && source "$HOME/.zshenv"
        """
        let zprofile = """
        [ -f "$HOME/.zprofile" ] && source "$HOME/.zprofile"
        """
        let zshrc = """
        # Ghost: config del usuario primero, luego nuestros hooks
        [ -f "$HOME/.zshrc" ] && source "$HOME/.zshrc"
        export ZDOTDIR="$HOME"  # shells anidados usan la config normal

        autoload -Uz add-zsh-hook

        __ciclope_preexec() {
            [ -n "$CICLOPE_EVENTS" ] || return 0
            local b64=$(print -rn -- "$1" | /usr/bin/base64 | tr -d '\\n')
            print -r -- "{\\"t\\":\\"exec\\",\\"cmd\\":\\"$b64\\"}" >> "$CICLOPE_EVENTS" 2>/dev/null
            __CICLOPE_RUNNING=1
        }

        __ciclope_precmd() {
            local ec=$?
            [ -n "$CICLOPE_EVENTS" ] || return 0
            # volcar el entorno exportado (para poder migrar la sesión)
            [ -n "$CICLOPE_STATE" ] && typeset -px >| "$CICLOPE_STATE" 2>/dev/null
            if [ -n "$__CICLOPE_RUNNING" ]; then
                local cwd64=$(print -rn -- "$PWD" | /usr/bin/base64 | tr -d '\\n')
                print -r -- "{\\"t\\":\\"done\\",\\"exit\\":$ec,\\"cwd\\":\\"$cwd64\\"}" >> "$CICLOPE_EVENTS" 2>/dev/null
                unset __CICLOPE_RUNNING
            fi
        }

        add-zsh-hook preexec __ciclope_preexec
        add-zsh-hook precmd __ciclope_precmd

        # comando boo: sin argumentos la mascota resume la sesión; con texto, pregunta
        # al LLM con el contexto de esta terminal. (Se llama boo para no pisar el
        # comando ghost propio de Juan en ~/.local/bin). El alias noglob evita que
        # zsh expanda ? o * de la pregunta como comodines y reviente el comando.
        __ciclope_ask() {
            if [ -z "$CICLOPE_EVENTS" ]; then
                echo "boo: esto solo funciona dentro de Ghost.app"
                return 1
            fi
            local q64=$(print -rn -- "$*" | /usr/bin/base64 | tr -d '\\n')
            print -r -- "{\\"t\\":\\"ask\\",\\"q\\":\\"$q64\\"}" >> "$CICLOPE_EVENTS" 2>/dev/null
            echo "(boo) en ello..."
        }
        alias boo='noglob __ciclope_ask'
        """
        try? zshenv.write(to: zdotdir.appendingPathComponent(".zshenv"), atomically: true, encoding: .utf8)
        try? zprofile.write(to: zdotdir.appendingPathComponent(".zprofile"), atomically: true, encoding: .utf8)
        try? zshrc.write(to: zdotdir.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
    }

    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.drain()
        }
    }

    private func drain() {
        guard let fh = try? FileHandle(forReadingFrom: eventsURL) else { return }
        defer { try? fh.close() }
        try? fh.seek(toOffset: offset)
        guard let data = try? fh.readToEnd(), !data.isEmpty else { return }
        offset += UInt64(data.count)

        guard let text = String(data: data, encoding: .utf8) else { return }
        for line in text.split(separator: "\n") {
            guard let d = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let t = json["t"] as? String else { continue }
            switch t {
            case "exec":
                if let cmd = Self.b64(json["cmd"]) { onExec?(cmd) }
            case "done":
                if let exit = json["exit"] as? Int {
                    onDone?(exit, Self.b64(json["cwd"]))
                }
            case "ask":
                onAsk?(Self.b64(json["q"]) ?? "")
            default:
                break
            }
        }
    }

    private static func b64(_ value: Any?) -> String? {
        guard let s = value as? String, let d = Data(base64Encoded: s) else { return nil }
        return String(data: d, encoding: .utf8)
    }
}

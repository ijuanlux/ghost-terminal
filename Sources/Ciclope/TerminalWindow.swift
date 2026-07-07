import AppKit
import SwiftTerm

// Subclase para capturar el output crudo del shell (contexto para el cerebro)
// y aceptar ficheros arrastrados (escribe la ruta escapada, como Terminal.app).
final class CiclopeTerminalView: LocalProcessTerminalView {
    var onOutput: ((ArraySlice<UInt8>) -> Void)?
    weak var session: TerminalSession?
    /// Se dispara una vez cuando la vista ya tiene su ancho real (>420px): el
    /// replay del scrollback necesita el tamaño definitivo para no partir líneas.
    var onReady: (() -> Void)?

    private let ghostScroller = GhostScrollBar()

    override func layout() {
        super.layout()
        if onReady != nil, bounds.width > 420 {
            let cb = onReady
            onReady = nil
            cb?()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        setupGhostScroller()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
        setupGhostScroller()
    }

    private func setupGhostScroller() {
        // esconder el NSScroller legacy de SwiftTerm (gris, invisible en oscuro)
        DispatchQueue.main.async { [weak self] in
            self?.subviews.first { $0 is NSScroller }?.isHidden = true
        }
        ghostScroller.terminalView = self
        ghostScroller.translatesAutoresizingMaskIntoConstraints = false
        addSubview(ghostScroller)
        NSLayoutConstraint.activate([
            ghostScroller.trailingAnchor.constraint(equalTo: trailingAnchor),
            ghostScroller.topAnchor.constraint(equalTo: topAnchor),
            ghostScroller.bottomAnchor.constraint(equalTo: bottomAnchor),
            ghostScroller.widthAnchor.constraint(equalToConstant: 13),
        ])
    }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        onOutput?(slice)
        super.dataReceived(slice: slice)
    }

    // MARK: - Scroll decente
    // El de SwiftTerm usa event.deltaY legacy: trunca los deltas fraccionales del
    // trackpad (a veces 0 → no se mueve) y con gestos rápidos salta páginas enteras.
    // Además ignora el mouse reporting y la pantalla alternativa.

    private var scrollAccumulator: CGFloat = 0

    func handleScroll(with event: NSEvent) {
        let terminal = getTerminal()

        // 1) La app de dentro pide los eventos de ratón (htop, claude...): reenviar rueda
        // (equivale a mouseMode.sendButtonPress(), que es internal en SwiftTerm)
        let reportsMouse: Bool
        switch terminal.mouseMode {
        case .off: reportsMouse = false
        default: reportsMouse = true
        }
        if allowMouseReporting && reportsMouse {
            let loc = convert(event.locationInWindow, from: nil)
            let cellW = max(1, frame.width / CGFloat(max(terminal.cols, 1)))
            let cellH = max(1, frame.height / CGFloat(max(terminal.rows, 1)))
            let col = max(0, min(terminal.cols - 1, Int(loc.x / cellW)))
            let row = max(0, min(terminal.rows - 1, Int((frame.height - loc.y) / cellH)))
            let button = event.scrollingDeltaY > 0 ? 64 : 65   // rueda arriba / abajo
            guard event.scrollingDeltaY != 0 else { return }
            terminal.sendEvent(buttonFlags: button, x: col, y: row)
            return
        }

        // 2) Convertir el delta a líneas: preciso (trackpad) acumulando puntos,
        //    clásico (rueda de ratón) en pasos de 3 líneas
        let lineH = max(8, ceil(font.ascender - font.descender + font.leading))
        var lines = 0
        if event.hasPreciseScrollingDeltas {
            scrollAccumulator += event.scrollingDeltaY
            lines = Int(scrollAccumulator / lineH)
            scrollAccumulator -= CGFloat(lines) * lineH
        } else {
            lines = Int(event.scrollingDeltaY.rounded()) * 3
        }
        guard lines != 0 else { return }

        // 3) Pantalla alternativa sin scrollback (vim, less): mandar flechas
        if terminal.isCurrentBufferAlternate {
            let up = lines > 0
            let seq = terminal.applicationCursor
                ? (up ? "\u{1B}OA" : "\u{1B}OB")
                : (up ? "\u{1B}[A" : "\u{1B}[B")
            for _ in 0..<min(abs(lines), 10) { send(txt: seq) }
            return
        }

        // 4) Buffer normal: scrollback de toda la vida, suave
        if lines > 0 {
            scrollUp(lines: lines)
        } else {
            scrollDown(lines: -lines)
        }
    }

    // MARK: - Menú contextual (botón derecho)

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: L.t("menu.copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "")
        menu.addItem(withTitle: L.t("menu.paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "")
        menu.addItem(withTitle: L.t("menu.selectAll"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        let boo = menu.addItem(withTitle: L.t("ctx.askBoo"), action: #selector(ctxAskBoo(_:)), keyEquivalent: "")
        boo.target = self
        menu.addItem(.separator())
        let clear = menu.addItem(withTitle: L.t("ctx.clear"), action: #selector(ctxClear(_:)), keyEquivalent: "")
        clear.target = self
        let finder = menu.addItem(withTitle: L.t("ctx.finder"), action: #selector(ctxFinder(_:)), keyEquivalent: "")
        finder.target = self
        return menu
    }

    /// Copia la selección al portapapeles y se la pasa a boo para que la explique.
    @objc private func ctxAskBoo(_ sender: Any?) {
        copy(sender ?? self)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, let text = NSPasteboard.general.string(forType: .string),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            self.session?.askBoo(about: String(text.prefix(1200)))
        }
    }

    @objc private func ctxClear(_ sender: Any?) {
        send(txt: "\u{0C}")   // Ctrl+L: limpia sin ejecutar nada visible
    }

    @objc private func ctxFinder(_ sender: Any?) {
        let cwd = session?.currentDirectory ?? NSHomeDirectory()
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: cwd)
    }

    // MARK: - Drag & drop de ficheros

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: nil) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
              !urls.isEmpty else { return false }
        let paths = urls.map { Self.shellEscape($0.path) }.joined(separator: " ")
        send(txt: paths + " ")
        window?.makeFirstResponder(self)
        return true
    }

    /// Escapa una ruta al estilo Terminal.app: backslash delante de cada
    /// carácter especial, sin comillas.
    private static func shellEscape(_ path: String) -> String {
        let special: Set<Character> = [" ", "'", "\"", "\\", "(", ")", "[", "]", "{", "}",
                                       "$", "`", "!", "&", ";", "<", ">", "|", "*", "?",
                                       "~", "#", "%", "="]
        var out = ""
        for ch in path {
            if special.contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }
}

private final class ThinSplitView: NSSplitView {
    override var dividerColor: NSColor { Theme.divider }
    override var dividerThickness: CGFloat { 2 }
}

// Ventana principal: terminal grande + columna izquierda y fila superior de
// paneles extra. ⌘T añade panel a la izquierda; los paneles se arrastran por su
// barra para moverse entre izquierda/arriba o desancharse a ventana propia.
final class TerminalWindowController: NSWindowController, NSWindowDelegate, NSSplitViewDelegate {

    private var rootSplit: ThinSplitView!    // [izquierda | centro]
    private var centerSplit: ThinSplitView!  // [arriba / principal]
    private var mainPair: ThinSplitView!     // [principal | división central]
    private var leftStack: ThinSplitView?    // paneles apilados
    private var topRow: ThinSplitView?       // paneles en fila
    private var mainContainer: NSView!
    private var sidebar: TabSidebarView!

    private var tabs: [TerminalSession] = []
    private var activeIndex = 0
    private var sidePanes: [TerminalPane] = []
    private var cyclops: CyclopsView!
    private var bubble: BubbleView!
    private var commandBubble: BubbleView!
    private let brain = Brain()
    private var mouseMonitor: Any?
    private var scrollMonitor: Any?
    private var fontSize: CGFloat = Prefs.fontSize
    private let dropHint = NSView()
    var onClose: ((TerminalWindowController) -> Void)?

    convenience init(greet: Bool, adopting session: TerminalSession? = nil) {
        let rect = NSRect(x: 0, y: 0, width: 980, height: 640)
        let window = NSWindow(
            contentRect: rect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        self.init(window: window)

        window.title = "ghost"
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Theme.bg
        window.minSize = NSSize(width: 480, height: 300)
        window.tabbingMode = .disallowed
        window.delegate = self
        window.center()

        let content = NSView(frame: rect)
        content.wantsLayer = true
        content.layer?.backgroundColor = Theme.bg.cgColor
        window.contentView = content

        setupSidebar(in: content)
        setupSplits(in: content)
        addTab(session: session ?? TerminalSession(fontSize: Prefs.fontSize, banner: greet && Prefs.showBanner))
        setupCyclops(in: content)
        setupDropHint(in: content)
        if greet { brain.greet() }
    }

    // MARK: - Layout

    private func setupSidebar(in content: NSView) {
        sidebar = TabSidebarView(frame: NSRect(x: 8, y: 8, width: 150,
                                               height: content.bounds.height - 42))
        sidebar.autoresizingMask = [.height]
        sidebar.isHidden = true
        content.addSubview(sidebar)

        sidebar.onSelect = { [weak self] i in self?.selectTab(i) }
        sidebar.onCloseTab = { [weak self] i in self?.closeTab(i) }
        sidebar.onMove = { [weak self] from, to in self?.moveTab(from: from, to: to) }
        sidebar.onDragMoved = { [weak self] point in
            guard let self, let content = self.window?.contentView else { return }
            if self.pointOverSidebar(point) {
                self.dropHint.isHidden = true
            } else {
                self.showDropHint(self.dropZone(for: point), in: content)
            }
        }
        sidebar.onDropBeyond = { [weak self] i, point in
            self?.dropHint.isHidden = true
            self?.tabDropped(i, at: point)
        }
        sidebar.onRename = { [weak self] i, name in
            guard let self, self.tabs.indices.contains(i) else { return }
            self.tabs[i].customName = name.isEmpty ? nil : name
            self.refreshSidebar()
        }
    }

    private func setupSplits(in content: NSView) {
        rootSplit = ThinSplitView(frame: NSRect(x: 8, y: 8,
                                                width: content.bounds.width - 16,
                                                height: content.bounds.height - 42))
        rootSplit.autoresizingMask = [.width, .height]
        rootSplit.isVertical = true
        rootSplit.dividerStyle = .thin
        rootSplit.delegate = self

        centerSplit = ThinSplitView(frame: rootSplit.bounds)
        centerSplit.isVertical = false
        centerSplit.dividerStyle = .thin
        centerSplit.delegate = self

        mainPair = ThinSplitView(frame: rootSplit.bounds)
        mainPair.isVertical = true
        mainPair.dividerStyle = .thin
        mainPair.delegate = self

        mainContainer = NSView()
        mainPair.addArrangedSubview(mainContainer)
        centerSplit.addArrangedSubview(mainPair)
        rootSplit.addArrangedSubview(centerSplit)
        content.addSubview(rootSplit)
    }

    // MARK: - Pestañas

    @discardableResult
    func addTab(session: TerminalSession? = nil) -> TerminalSession {
        let s = session ?? TerminalSession(fontSize: fontSize, banner: Prefs.showBanner)
        wire(s)
        tabs.append(s)
        selectTab(tabs.count - 1)
        if brain.attached == nil { brain.attach(s, announce: false) }
        return s
    }

    private func wire(_ s: TerminalSession) {
        s.brain = brain
        s.onTitleChange = { [weak self, weak s] _ in
            guard let self, let s else { return }
            if self.tabs.indices.contains(self.activeIndex), self.tabs[self.activeIndex] === s {
                self.window?.title = s.displayName
            }
            self.refreshSidebar()
        }
        s.onActivity = { [weak self] in self?.refreshSidebar() }
        s.onExited = { [weak self, weak s] _ in
            guard let self, let s, let i = self.tabs.firstIndex(where: { $0 === s }) else { return }
            self.closeTab(i, terminateProcess: false)
        }
    }

    func selectTab(_ i: Int) {
        guard tabs.indices.contains(i) else { return }
        activeIndex = i
        mainContainer.subviews.forEach { $0.removeFromSuperview() }
        let tv = tabs[i].view
        tv.removeFromSuperview()
        tv.translatesAutoresizingMaskIntoConstraints = false
        mainContainer.addSubview(tv)
        NSLayoutConstraint.activate([
            tv.topAnchor.constraint(equalTo: mainContainer.topAnchor, constant: 2),
            tv.leadingAnchor.constraint(equalTo: mainContainer.leadingAnchor),
            tv.trailingAnchor.constraint(equalTo: mainContainer.trailingAnchor),
            tv.bottomAnchor.constraint(equalTo: mainContainer.bottomAnchor),
        ])
        window?.title = tabs[i].displayName
        window?.makeFirstResponder(tv)
        refreshSidebar()
        tabs[i].resumeIfPending()
    }

    func closeTab(_ i: Int, terminateProcess: Bool = true) {
        guard tabs.indices.contains(i) else { return }
        let s = tabs[i]
        let wasGhostHome = (brain.attached === s)
        s.onExited = nil
        if terminateProcess { s.terminate() }
        tabs.remove(at: i)
        if tabs.isEmpty {
            window?.close()
            return
        }
        selectTab(min(activeIndex >= i ? activeIndex - 1 : activeIndex, tabs.count - 1))
        if wasGhostHome { brain.attach(tabs[activeIndex], announce: false) }
    }

    func moveTab(from: Int, to: Int) {
        guard tabs.indices.contains(from), tabs.indices.contains(to) else { return }
        let current = tabs[activeIndex]
        let s = tabs.remove(at: from)
        tabs.insert(s, at: to)
        activeIndex = tabs.firstIndex { $0 === current } ?? 0
        refreshSidebar()
    }

    /// Saca la pestaña i de la lista sin matar su sesión.
    private func removeTabKeepingSession(_ i: Int) -> TerminalSession? {
        guard tabs.indices.contains(i), tabs.count > 1 else { return nil }
        let s = tabs[i]
        s.onExited = nil
        s.onTitleChange = nil
        s.onActivity = nil
        tabs.remove(at: i)
        if activeIndex >= tabs.count { activeIndex = tabs.count - 1 }
        selectTab(activeIndex)
        return s
    }

    func detachTab(_ i: Int, at screenPoint: NSPoint) {
        guard let s = removeTabKeepingSession(i) else { return }
        if brain.attached === s, tabs.indices.contains(activeIndex) {
            brain.attach(tabs[activeIndex], announce: false)
        }
        (NSApp.delegate as? AppDelegate)?.openWindow(greet: false, adopting: s, at: screenPoint)
    }

    /// Pestaña soltada fuera de la sidebar: división central, dock o ventana nueva.
    private func tabDropped(_ i: Int, at screenPoint: NSPoint) {
        switch dropZone(for: screenPoint) {
        case .out:
            detachTab(i, at: screenPoint)
        case .right:
            guard let s = removeTabKeepingSession(i) else { return }
            addSidePane(.right, session: s)
        case .left:
            guard let s = removeTabKeepingSession(i) else { return }
            addSidePane(.left, session: s)
        case .top:
            guard let s = removeTabKeepingSession(i) else { return }
            addSidePane(.top, session: s)
        case .tab, .none:
            return
        }
    }

    private func pointOverSidebar(_ screenPoint: NSPoint) -> Bool {
        guard let window, !sidebar.isHidden, window.frame.contains(screenPoint),
              let content = window.contentView else { return false }
        let local = content.convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        return sidebar.frame.insetBy(dx: -20, dy: -20).contains(local)
    }

    // MARK: - Ghost se muda de terminal

    /// Al soltar a Ghost sobre otra terminal visible: se muda a ella y migra
    /// la sesión (cd + variables de entorno) de la vieja a la nueva.
    private func ghostDropped(at screenPoint: NSPoint) {
        guard let window, window.frame.contains(screenPoint) else { return }
        let wp = window.convertPoint(fromScreen: screenPoint)

        var candidates: [TerminalSession] = sidePanes.map { $0.session }
        if tabs.indices.contains(activeIndex) { candidates.append(tabs[activeIndex]) }

        guard let target = candidates.first(where: { s in
            guard s.view.window === window else { return false }
            return s.view.convert(s.view.bounds, to: nil).contains(wp)
        }) else { return }

        let old = brain.attached
        guard target !== old else { return }
        brain.attach(target, migrateFrom: old)
        if let old { migrateSession(from: old, to: target) }
    }

    /// Inyecta en la terminal destino el cd y el entorno exportado de la origen.
    private func migrateSession(from old: TerminalSession, to new: TerminalSession) {
        var lines = ["# Ghost: sesión migrada desde otra terminal"]
        if let cwd = old.currentDirectory, !cwd.isEmpty {
            lines.append("cd '\(cwd.replacingOccurrences(of: "'", with: "'\\''"))'")
        }

        // variables exportadas de la sesión origen, filtrando las de sistema/sesión
        let blacklist: Set<String> = [
            "PWD", "OLDPWD", "SHLVL", "_", "TERM", "TERM_PROGRAM", "TERM_SESSION_ID",
            "ZDOTDIR", "TMPDIR", "XPC_FLAGS", "XPC_SERVICE_NAME", "SECURITYSESSIONID",
            "SHELL", "HOME", "USER", "LOGNAME", "PATH", "COLORTERM", "SSH_AUTH_SOCK",
            "CICLOPE_EVENTS", "CICLOPE_STATE", "DISPLAY", "LaunchInstanceID",
        ]
        if let env = try? String(contentsOf: old.stateURL, encoding: .utf8) {
            for line in env.split(separator: "\n") {
                guard let eq = line.firstIndex(of: "="),
                      let name = line[..<eq].split(separator: " ").last,
                      name.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil,
                      !blacklist.contains(String(name)),
                      !name.hasPrefix("__CF") else { continue }
                lines.append(String(line))
            }
        }

        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ciclope", isDirectory: true)
        let script = support.appendingPathComponent("migrate.zsh")
        guard (try? lines.joined(separator: "\n").write(to: script, atomically: true, encoding: .utf8)) != nil else { return }
        new.send("source '\(script.path)'\n")
    }

    func nextTab() { selectTab((activeIndex + 1) % max(tabs.count, 1)) }
    func prevTab() { selectTab((activeIndex - 1 + tabs.count) % max(tabs.count, 1)) }
    func selectTabNumber(_ n: Int) { selectTab(n - 1) }

    private func refreshSidebar() {
        sidebar.update(items: tabs.map { .init(name: $0.displayName, subtitle: $0.subtitle) }, active: activeIndex)
        layoutChrome()
    }

    private func layoutChrome() {
        guard let content = window?.contentView else { return }
        let showSidebar = tabs.count > 1
        sidebar.isHidden = !showSidebar
        let x: CGFloat = showSidebar ? 164 : 8
        rootSplit.frame = NSRect(x: x, y: 8,
                                 width: content.bounds.width - x - 8,
                                 height: content.bounds.height - 42)
    }

    private func setupCyclops(in content: NSView) {
        let sprite = CyclopsView.spriteSize
        let off = CyclopsView.savedOffset
        cyclops = CyclopsView(frame: NSRect(x: content.bounds.width - sprite.width - off.dx,
                                            y: off.dy, width: sprite.width, height: sprite.height))
        cyclops.autoresizingMask = [.minXMargin, .maxYMargin]
        content.addSubview(cyclops, positioned: .above, relativeTo: rootSplit)

        bubble = BubbleView(frame: NSRect(x: content.bounds.width - 262,
                                          y: off.dy + sprite.height + 8, width: 250, height: 40))
        bubble.autoresizingMask = [.minXMargin, .maxYMargin]
        bubble.anchor = cyclops
        content.addSubview(bubble, positioned: .above, relativeTo: cyclops)

        commandBubble = BubbleView(frame: NSRect(x: content.bounds.width - 262,
                                                 y: off.dy + sprite.height + 8, width: 250, height: 40))
        commandBubble.autoresizingMask = [.minXMargin, .maxYMargin]
        commandBubble.anchor = cyclops
        commandBubble.commandStyle = true
        content.addSubview(commandBubble, positioned: .above, relativeTo: cyclops)

        brain.cyclops = cyclops
        brain.bubble = bubble
        brain.commandBubble = commandBubble
        cyclops.onClick = { [weak self] in self?.brain.onDemandSummary() }
        cyclops.onMoved = { [weak self] in
            self?.commandBubble.follow()
            self?.bubble.follow()
        }
        cyclops.onDropped = { [weak self] screenPoint in self?.ghostDropped(at: screenPoint) }

        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            self.cyclops.lookToward(windowPoint: event.locationInWindow)
            // Anti-jiggler: si la app de dentro (claude, htop...) tiene rastreo de
            // movimiento de ratón activo, los movimientos del puntero se convierten
            // en secuencias de escape que le ensucian el input. Los tragamos aquí:
            // clicks, arrastres y rueda siguen pasando, el movimiento a secas no.
            if let frameView = self.window?.contentView?.superview,
               var v = frameView.hitTest(event.locationInWindow) {
                while !(v is CiclopeTerminalView) {
                    guard let parent = v.superview else { return event }
                    v = parent
                }
                if let term = v as? CiclopeTerminalView,
                   case .anyEvent = term.getTerminal().mouseMode {
                    return nil
                }
            }
            return event
        }
        // el scrollWheel de SwiftTerm no es open: interceptamos la rueda aquí
        // y la mandamos a nuestra implementación decente (handleScroll)
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
            guard let self, event.window === self.window,
                  let frameView = self.window?.contentView?.superview,
                  var v = frameView.hitTest(event.locationInWindow) else { return event }
            while !(v is CiclopeTerminalView) {
                guard let parent = v.superview else { return event }
                v = parent
            }
            (v as? CiclopeTerminalView)?.handleScroll(with: event)
            return nil
        }
        window?.acceptsMouseMovedEvents = true
    }

    private func setupDropHint(in content: NSView) {
        dropHint.wantsLayer = true
        dropHint.layer?.backgroundColor = Theme.accent.withAlphaComponent(0.12).cgColor
        dropHint.layer?.borderColor = Theme.accent.withAlphaComponent(0.7).cgColor
        dropHint.layer?.borderWidth = 1
        dropHint.layer?.cornerRadius = 4
        dropHint.isHidden = true
        content.addSubview(dropHint, positioned: .above, relativeTo: rootSplit)
    }

    // MARK: - Paneles

    enum Dock { case left, top, right }

    @discardableResult
    func addSidePane(_ dock: Dock = .left, session: TerminalSession? = nil) -> TerminalPane {
        let s = session ?? TerminalSession(fontSize: fontSize)
        s.brain = brain
        let pane = TerminalPane(session: s)
        s.onExited = { [weak self, weak pane] _ in
            guard let pane else { return }
            self?.closePane(pane)
        }
        pane.onCloseRequested = { [weak self] p in
            p.session.terminate()
            self?.closePane(p)
        }
        pane.onDrag = { [weak self] p, phase, screenPoint in
            self?.handlePaneDrag(p, phase: phase, screenPoint: screenPoint)
        }
        sidePanes.append(pane)
        attach(pane, to: dock)
        pane.focus()
        s.resumeIfPending()
        return pane
    }

    private func attach(_ pane: TerminalPane, to dock: Dock) {
        switch dock {
        case .left:
            if leftStack == nil {
                let stack = ThinSplitView()
                stack.isVertical = false
                stack.dividerStyle = .thin
                stack.delegate = self
                leftStack = stack
                rootSplit.insertArrangedSubview(stack, at: 0)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.rootSplit.setPosition(min(360, self.rootSplit.bounds.width * 0.34), ofDividerAt: 0)
                }
            }
            leftStack!.addArrangedSubview(pane)
            leftStack!.adjustSubviews()
        case .top:
            if topRow == nil {
                let row = ThinSplitView()
                row.isVertical = true
                row.dividerStyle = .thin
                row.delegate = self
                topRow = row
                centerSplit.insertArrangedSubview(row, at: 0)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.centerSplit.setPosition(min(260, self.centerSplit.bounds.height * 0.35), ofDividerAt: 0)
                }
            }
            topRow!.addArrangedSubview(pane)
            topRow!.adjustSubviews()
        case .right:
            // división doble del área central: principal | panel
            mainPair.addArrangedSubview(pane)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.mainPair.arrangedSubviews.count == 2 {
                    self.mainPair.setPosition(self.mainPair.bounds.width / 2, ofDividerAt: 0)
                } else {
                    self.mainPair.adjustSubviews()
                }
            }
        }
    }

    private func detachFromSplit(_ pane: TerminalPane) {
        pane.removeFromSuperview()
        if let stack = leftStack, stack.arrangedSubviews.isEmpty {
            stack.removeFromSuperview()
            leftStack = nil
        }
        if let row = topRow, row.arrangedSubviews.isEmpty {
            row.removeFromSuperview()
            topRow = nil
        }
    }

    func closePane(_ pane: TerminalPane) {
        sidePanes.removeAll { $0 === pane }
        detachFromSplit(pane)
        if brain.attached === pane.session || brain.attached == nil,
           tabs.indices.contains(activeIndex) {
            brain.attach(tabs[activeIndex], announce: false)
        }
    }

    /// ⌘W: cierra el panel enfocado, si no la pestaña activa, si no la ventana.
    func closeFocusedPaneOrWindow() {
        if let responder = window?.firstResponder as? NSView,
           let pane = sidePanes.first(where: { responder.isDescendant(of: $0) }) {
            pane.session.terminate()
            closePane(pane)
        } else if tabs.count > 1 {
            closeTab(activeIndex)
        } else {
            window?.performClose(nil)
        }
    }

    // MARK: - Drag de paneles y pestañas

    private enum DropZone { case tab, left, top, right, out, none }

    private func dropZone(for screenPoint: NSPoint, forPane: Bool = false) -> DropZone {
        guard let window, let content = window.contentView else { return .none }
        if !window.frame.contains(screenPoint) { return .out }
        let local = content.convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        // la franja de la sidebar: para un panel significa "volver a ser pestaña"
        if forPane && local.x < 175 { return .tab }
        if local.x < content.bounds.width * 0.30 { return .left }
        if local.y > content.bounds.height * 0.68 { return .top }
        if local.x > content.bounds.width * 0.48 { return .right }
        return .none
    }

    private func handlePaneDrag(_ pane: TerminalPane, phase: TerminalPane.DragPhase, screenPoint: NSPoint) {
        guard let content = window?.contentView else { return }
        let zone = dropZone(for: screenPoint, forPane: true)
        switch phase {
        case .moved:
            showDropHint(zone, in: content)
        case .ended:
            dropHint.isHidden = true
            applyDrop(pane, zone: zone, screenPoint: screenPoint)
        }
    }

    private func showDropHint(_ zone: DropZone, in content: NSView) {
        switch zone {
        case .tab:
            dropHint.frame = NSRect(x: 8, y: 8, width: 158, height: content.bounds.height - 42)
            dropHint.isHidden = false
        case .left:
            dropHint.frame = NSRect(x: 8, y: 8, width: content.bounds.width * 0.30 - 8,
                                    height: content.bounds.height - 42)
            dropHint.isHidden = false
        case .top:
            dropHint.frame = NSRect(x: 8, y: content.bounds.height * 0.68,
                                    width: content.bounds.width - 16,
                                    height: content.bounds.height * 0.32 - 34)
            dropHint.isHidden = false
        case .right:
            dropHint.frame = NSRect(x: content.bounds.width * 0.48, y: 8,
                                    width: content.bounds.width * 0.52 - 8,
                                    height: content.bounds.height * 0.68 - 8)
            dropHint.isHidden = false
        case .out, .none:
            dropHint.isHidden = true
        }
    }

    private func applyDrop(_ pane: TerminalPane, zone: DropZone, screenPoint: NSPoint) {
        switch zone {
        case .none:
            return
        case .tab:
            // panel de vuelta a pestaña
            sidePanes.removeAll { $0 === pane }
            detachFromSplit(pane)
            let s = pane.session
            s.view.removeFromSuperview()
            addTab(session: s)
        case .left:
            guard pane.superview !== leftStack else { return }
            detachFromSplit(pane)
            attach(pane, to: .left)
        case .top:
            guard pane.superview !== topRow else { return }
            detachFromSplit(pane)
            attach(pane, to: .top)
        case .right:
            guard pane.superview !== mainPair else { return }
            detachFromSplit(pane)
            attach(pane, to: .right)
        case .out:
            // desanclar: el panel se convierte en ventana propia (misma sesión viva)
            sidePanes.removeAll { $0 === pane }
            detachFromSplit(pane)
            let session = pane.session
            (NSApp.delegate as? AppDelegate)?.openWindow(greet: false, adopting: session, at: screenPoint)
        }
    }

    // MARK: - Acciones

    func adjustFont(delta: CGFloat) {
        applyFontSize(fontSize + delta)
        Prefs.fontSize = fontSize
    }

    func applyFontSize(_ size: CGFloat) {
        fontSize = max(9, min(28, size))
        tabs.forEach { $0.setFontSize(fontSize) }
        sidePanes.forEach { $0.session.setFontSize(fontSize) }
    }

    func toggleCyclops() {
        cyclops.isHidden.toggle()
        if cyclops.isHidden {
            bubble.dismiss()
            commandBubble.dismiss()
        }
    }

    // MARK: - Persistencia

    /// Estado serializable de la ventana completa (pestañas, paneles, marco).
    func stateSnapshot() -> [String: Any] {
        var dict: [String: Any] = [:]
        if let window { dict["frame"] = NSStringFromRect(window.frame) }
        dict["activeIndex"] = activeIndex
        dict["tabs"] = tabs.map { $0.snapshot() }
        dict["panes"] = sidePanes.map { pane -> [String: Any] in
            var d = pane.session.snapshot()
            if pane.superview === leftStack { d["dock"] = "left" }
            else if pane.superview === topRow { d["dock"] = "top" }
            else { d["dock"] = "right" }
            return d
        }
        return dict
    }

    /// IDs de todas las sesiones vivas (para no borrar sus logs).
    var sessionIDs: [String] {
        tabs.map { $0.id } + sidePanes.map { $0.session.id }
    }

    /// Re-aplica el tema activo a toda la ventana en caliente.
    func applyTheme() {
        window?.backgroundColor = Theme.bg
        window?.contentView?.layer?.backgroundColor = Theme.bg.cgColor
        tabs.forEach { $0.applyTheme() }
        sidePanes.forEach { $0.applyTheme() }
        sidebar.applyTheme()
        refreshSidebar()
        bubble.applyTheme()
        commandBubble.applyTheme()
        dropHint.layer?.backgroundColor = Theme.accent.withAlphaComponent(0.12).cgColor
        dropHint.layer?.borderColor = Theme.accent.withAlphaComponent(0.7).cgColor
        [rootSplit, centerSplit, mainPair, leftStack, topRow].forEach { $0?.needsDisplay = true }
    }

    // MARK: - NSSplitViewDelegate

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(proposedMinimumPosition, 110)
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        let limit = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
        return min(proposedMaximumPosition, limit - 110)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
        // matar los shells para no dejar zombies
        tabs.forEach { $0.terminate() }
        sidePanes.forEach { $0.session.terminate() }
        onClose?(self)
    }
}

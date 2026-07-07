import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controllers: [TerminalWindowController] = []
    private var themeMenu: NSMenu?

    private var autosaveTimer: Timer?

    private var stateURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ciclope", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("restore.json")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Theme.restore()
        buildMenu()
        autosaveTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            self?.saveState()
        }
        if ProcessInfo.processInfo.environment["CICLOPE_TEST_SETTINGS"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.openSettings(nil)
            }
        }
        if restoreState() {
            return
        }
        let wc = openWindow(greet: true)
        // hooks de pruebas: CICLOPE_TEST_TABS=N / CICLOPE_TEST_PANES=N al arrancar
        let env = ProcessInfo.processInfo.environment
        if let n = Int(env["CICLOPE_TEST_TABS"] ?? ""), n > 0 {
            for i in 0..<n {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 + Double(i) * 0.6) {
                    wc.addTab()
                }
            }
        }
        if env["CICLOPE_TEST_RIGHT"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                wc.addSidePane(.right)
            }
        }
        if let n = Int(env["CICLOPE_TEST_PANES"] ?? ""), n > 0 {
            for i in 0..<n {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 + Double(i) * 0.6) {
                    wc.addSidePane(.left)
                }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        // si ya no queda ninguna ventana, el estado bueno se guardó al cerrarla
        if !controllers.isEmpty { saveState() }
    }

    // MARK: - Persistencia de sesiones

    /// Guarda el estado de todas las ventanas abiertas (pestañas, paneles,
    /// directorios, memoria de Ghost). El scrollback ya vive en los .log.
    func saveState() {
        guard !controllers.isEmpty else { return }
        let dict: [String: Any] = ["windows": controllers.map { $0.stateSnapshot() }]
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: []) else { return }
        try? data.write(to: stateURL)

        // limpiar logs huérfanos
        let alive = Set(controllers.flatMap { $0.sessionIDs })
        let dir = TerminalSession.sessionsDir
        if let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
            for f in files where f.hasSuffix(".log") {
                let id = String(f.dropLast(4))
                if !alive.contains(id) {
                    try? FileManager.default.removeItem(at: dir.appendingPathComponent(f))
                }
            }
        }
    }

    /// Reconstruye las ventanas de la última sesión. Devuelve false si no había nada.
    private func restoreState() -> Bool {
        guard let data = try? Data(contentsOf: stateURL),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let windows = dict["windows"] as? [[String: Any]], !windows.isEmpty else { return false }

        for (wi, w) in windows.enumerated() {
            let tabDicts = (w["tabs"] as? [[String: Any]]) ?? []
            let sessions = tabDicts.compactMap { TerminalSession.restoreInfo(from: $0) }
                .map { TerminalSession(fontSize: 13, restore: $0) }
            guard let first = sessions.first else { continue }

            let wc = openWindow(greet: wi == 0, adopting: first)
            for s in sessions.dropFirst() { wc.addTab(session: s) }

            for p in (w["panes"] as? [[String: Any]]) ?? [] {
                guard let info = TerminalSession.restoreInfo(from: p) else { continue }
                let dock: TerminalWindowController.Dock = {
                    switch p["dock"] as? String {
                    case "top": return .top
                    case "right": return .right
                    default: return .left
                    }
                }()
                wc.addSidePane(dock, session: TerminalSession(fontSize: 13, restore: info))
            }

            if let active = w["activeIndex"] as? Int { wc.selectTab(active) }
            if let frameStr = w["frame"] as? String, let window = wc.window {
                window.setFrame(NSRectFromString(frameStr), display: true)
            }
        }
        return !controllers.isEmpty
    }

    @discardableResult
    func openWindow(greet: Bool, adopting session: TerminalSession? = nil,
                    at screenPoint: NSPoint? = nil) -> TerminalWindowController {
        let wc = TerminalWindowController(greet: greet, adopting: session)
        wc.onClose = { [weak self] closed in
            // guardar ANTES de quitarla: así cerrar la última ventana también persiste
            self?.saveState()
            self?.controllers.removeAll { $0 === closed }
        }
        controllers.append(wc)
        if let screenPoint, let w = wc.window {
            w.setFrameOrigin(NSPoint(x: screenPoint.x - w.frame.width / 2,
                                     y: screenPoint.y - w.frame.height + 30))
        }
        wc.showWindow(nil)
        wc.window?.makeKeyAndOrderFront(nil)
        return wc
    }

    private var keyController: TerminalWindowController? {
        controllers.first { $0.window?.isKeyWindow == true } ?? controllers.last
    }

    // MARK: - Acciones de menú

    @objc func newTab(_ sender: Any?) {
        if let kc = keyController { kc.addTab() }
        else { openWindow(greet: false) }
    }
    @objc func newSplit(_ sender: Any?) {
        if let kc = keyController { kc.addSidePane(.left) }
        else { openWindow(greet: false) }
    }
    @objc func newWindow(_ sender: Any?) { openWindow(greet: false) }
    @objc func closePane(_ sender: Any?) { keyController?.closeFocusedPaneOrWindow() }
    @objc func nextTab(_ sender: Any?) { keyController?.nextTab() }
    @objc func prevTab(_ sender: Any?) { keyController?.prevTab() }
    @objc func gotoTab(_ sender: Any?) {
        if let n = (sender as? NSMenuItem)?.tag { keyController?.selectTabNumber(n) }
    }
    @objc func biggerFont(_ sender: Any?) { keyController?.adjustFont(delta: 1) }
    @objc func smallerFont(_ sender: Any?) { keyController?.adjustFont(delta: -1) }
    @objc func toggleCyclops(_ sender: Any?) { keyController?.toggleCyclops() }

    @objc func changeTheme(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        applyThemeNamed(item.title)
    }

    // MARK: - Menú

    @objc func openSettings(_ sender: Any?) {
        SettingsWindowController.shared.show()
    }

    func applyThemeNamed(_ name: String) {
        Theme.select(name)
        controllers.forEach { $0.applyTheme() }
        themeMenu?.items.forEach { $0.state = ($0.title == Theme.current.name) ? .on : .off }
    }

    func applyFontSizeEverywhere() {
        controllers.forEach { $0.applyFontSize(Prefs.fontSize) }
    }

    func buildMenu() {
        let main = NSMenu()

        // App
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L.t("menu.about"),
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L.t("menu.settings"), action: #selector(openSettings(_:)), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L.t("menu.hide"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L.t("menu.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        // Shell
        let shellItem = NSMenuItem(); main.addItem(shellItem)
        let shellMenu = NSMenu(title: L.t("menu.shell"))
        shellMenu.addItem(withTitle: L.t("menu.newTab"), action: #selector(newTab(_:)), keyEquivalent: "t")
        shellMenu.addItem(withTitle: L.t("menu.split"), action: #selector(newSplit(_:)), keyEquivalent: "d")
        shellMenu.addItem(withTitle: L.t("menu.newWindow"), action: #selector(newWindow(_:)), keyEquivalent: "n")
        shellMenu.addItem(.separator())
        shellMenu.addItem(withTitle: L.t("menu.close"), action: #selector(closePane(_:)), keyEquivalent: "w")
        shellItem.submenu = shellMenu

        // Edición
        let editItem = NSMenuItem(); main.addItem(editItem)
        let editMenu = NSMenu(title: L.t("menu.edit"))
        editMenu.addItem(withTitle: L.t("menu.copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: L.t("menu.paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: L.t("menu.selectAll"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        // Vista
        let viewItem = NSMenuItem(); main.addItem(viewItem)
        let viewMenu = NSMenu(title: L.t("menu.view"))
        viewMenu.addItem(withTitle: L.t("menu.fontBigger"), action: #selector(biggerFont(_:)), keyEquivalent: "+")
        viewMenu.addItem(withTitle: L.t("menu.fontSmaller"), action: #selector(smallerFont(_:)), keyEquivalent: "-")
        viewMenu.addItem(.separator())
        let themeItem = NSMenuItem(title: L.t("menu.theme"), action: nil, keyEquivalent: "")
        let themes = NSMenu(title: L.t("menu.theme"))
        for palette in Theme.all {
            let item = NSMenuItem(title: palette.name, action: #selector(changeTheme(_:)), keyEquivalent: "")
            item.state = (palette.name == Theme.current.name) ? .on : .off
            themes.addItem(item)
        }
        themeItem.submenu = themes
        themeMenu = themes
        viewMenu.addItem(themeItem)
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: L.t("menu.toggleGhost"), action: #selector(toggleCyclops(_:)), keyEquivalent: "e")
        viewItem.submenu = viewMenu

        // Ventana
        let winItem = NSMenuItem(); main.addItem(winItem)
        let winMenu = NSMenu(title: L.t("menu.window"))
        winMenu.addItem(withTitle: L.t("menu.minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winMenu.addItem(.separator())
        let next = NSMenuItem(title: L.t("menu.nextTab"), action: #selector(nextTab(_:)), keyEquivalent: "]")
        next.keyEquivalentModifierMask = [.command, .shift]
        winMenu.addItem(next)
        let prev = NSMenuItem(title: L.t("menu.prevTab"), action: #selector(prevTab(_:)), keyEquivalent: "[")
        prev.keyEquivalentModifierMask = [.command, .shift]
        winMenu.addItem(prev)
        for n in 1...9 {
            let item = NSMenuItem(title: "\(L.t("menu.tab")) \(n)", action: #selector(gotoTab(_:)), keyEquivalent: "\(n)")
            item.tag = n
            winMenu.addItem(item)
        }
        NSApp.windowsMenu = winMenu
        winItem.submenu = winMenu

        NSApp.mainMenu = main
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()

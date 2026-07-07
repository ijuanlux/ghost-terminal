import AppKit

// Ventana de Ajustes (⌘,): idioma, tema, fuente, banner y resúmenes de IA.
// Todo aplica en caliente y persiste en UserDefaults.
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private var languagePopup: NSPopUpButton!
    private var themePopup: NSPopUpButton!
    private var fontStepper: NSStepper!
    private var fontLabel: NSTextField!
    private var bannerCheck: NSButton!
    private var summariesCheck: NSButton!
    private var actionsCheck: NSButton!
    private var introCheck: NSButton!

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.center()
        super.init(window: window)
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        buildUI()   // reconstruir con el idioma/estado actual
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildUI() {
        guard let window else { return }
        window.title = L.t("settings.title")

        let grid = NSGridView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 14
        grid.columnSpacing = 12

        // Idioma
        languagePopup = NSPopUpButton()
        languagePopup.addItems(withTitles: ["Español", "English"])
        languagePopup.selectItem(at: Prefs.language == "en" ? 1 : 0)
        languagePopup.target = self
        languagePopup.action = #selector(languageChanged)
        grid.addRow(with: [label(L.t("settings.language")), languagePopup])

        // Tema
        themePopup = NSPopUpButton()
        themePopup.addItems(withTitles: Theme.all.map { $0.name })
        themePopup.selectItem(withTitle: Theme.current.name)
        themePopup.target = self
        themePopup.action = #selector(themeChanged)
        grid.addRow(with: [label(L.t("settings.theme")), themePopup])

        // Fuente
        let fontRow = NSStackView()
        fontRow.orientation = .horizontal
        fontRow.spacing = 8
        fontLabel = label("\(Int(Prefs.fontSize)) pt")
        fontStepper = NSStepper()
        fontStepper.minValue = 9
        fontStepper.maxValue = 28
        fontStepper.increment = 1
        fontStepper.integerValue = Int(Prefs.fontSize)
        fontStepper.target = self
        fontStepper.action = #selector(fontChanged)
        fontRow.addArrangedSubview(fontLabel)
        fontRow.addArrangedSubview(fontStepper)
        grid.addRow(with: [label(L.t("settings.fontSize")), fontRow])

        // Banner
        bannerCheck = NSButton(checkboxWithTitle: L.t("settings.banner"),
                               target: self, action: #selector(bannerChanged))
        bannerCheck.state = Prefs.showBanner ? .on : .off
        grid.addRow(with: [NSGridCell.emptyContentView, bannerCheck])

        // Resúmenes IA
        summariesCheck = NSButton(checkboxWithTitle: L.t("settings.aiSummaries"),
                                  target: self, action: #selector(summariesChanged))
        summariesCheck.state = Prefs.aiSummaries ? .on : .off
        grid.addRow(with: [NSGridCell.emptyContentView, summariesCheck])

        actionsCheck = NSButton(checkboxWithTitle: L.t("settings.booActions"),
                                target: self, action: #selector(actionsChanged))
        actionsCheck.state = Prefs.booActions ? .on : .off
        grid.addRow(with: [NSGridCell.emptyContentView, actionsCheck])

        introCheck = NSButton(checkboxWithTitle: L.t("settings.intro"),
                              target: self, action: #selector(introChanged))
        introCheck.state = Prefs.showIntro ? .on : .off
        grid.addRow(with: [NSGridCell.emptyContentView, introCheck])

        let content = NSView(frame: window.contentLayoutRect)
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -28),
        ])
        window.contentView = content
    }

    private func label(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = NSFont.systemFont(ofSize: 13)
        return l
    }

    // MARK: - Acciones

    @objc private func languageChanged() {
        Prefs.language = languagePopup.indexOfSelectedItem == 1 ? "en" : "es"
        (NSApp.delegate as? AppDelegate)?.buildMenu()
        buildUI()
    }

    @objc private func themeChanged() {
        guard let name = themePopup.titleOfSelectedItem else { return }
        (NSApp.delegate as? AppDelegate)?.applyThemeNamed(name)
    }

    @objc private func fontChanged() {
        Prefs.fontSize = CGFloat(fontStepper.integerValue)
        fontLabel.stringValue = "\(fontStepper.integerValue) pt"
        (NSApp.delegate as? AppDelegate)?.applyFontSizeEverywhere()
    }

    @objc private func bannerChanged() {
        Prefs.showBanner = bannerCheck.state == .on
    }

    @objc private func summariesChanged() {
        Prefs.aiSummaries = summariesCheck.state == .on
    }

    @objc private func actionsChanged() {
        Prefs.booActions = actionsCheck.state == .on
    }

    @objc private func introChanged() {
        Prefs.showIntro = introCheck.state == .on
    }
}

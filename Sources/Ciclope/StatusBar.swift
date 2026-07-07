import AppKit

// Franja fina abajo de la ventana: fantasmita + contador de consultas que boo
// resolvió en local sin ir a la nube. Motiva a usar boo para lo simple.
final class StatusBarView: NSView {
    private let label = NSTextField(labelWithString: "")
    private var observer: NSObjectProtocol?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true

        label.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        label.isBezeled = false
        label.drawsBackground = false
        label.isEditable = false
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        observer = NotificationCenter.default.addObserver(
            forName: Prefs.statsChanged, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        }
        applyTheme()
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    func applyTheme() {
        layer?.backgroundColor = Theme.chromeBg.withAlphaComponent(0.6).cgColor
        refresh()
    }

    func refresh() {
        let q = Prefs.booQueries
        if q == 0 {
            label.stringValue = "👻  " + L.t("stats.zero")
            label.textColor = Theme.dimFg
            return
        }
        label.stringValue = "👻  " + String(format: L.t("stats"), q, Self.humanTokens(Prefs.booTokensSaved))
        label.textColor = Theme.accent.blended(withFraction: 0.25, of: Theme.fg) ?? Theme.accent
    }

    private static func humanTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.0fk", Double(n) / 1_000) }
        return "\(n)"
    }
}

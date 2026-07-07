import AppKit

// Bocadillo de texto del monstruo: borde fino verde, fondo negro translúcido,
// texto monospace que se escribe solo (efecto typewriter).
final class BubbleView: NSView {
    weak var anchor: NSView?   // sobre qué se coloca (el fantasma u otro bocadillo)
    var commandStyle = false   // bocadillo de comando: borde de acento y texto destacado
    private let label = NSTextField(wrappingLabelWithString: "")
    private var typeTimer: Timer?
    private var hideTimer: Timer?
    private var fullText = ""
    private var shown = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.82).cgColor
        layer?.borderColor = Theme.accent.withAlphaComponent(0.7).cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 6
        alphaValue = 0

        label.font = Theme.font(size: 11)
        label.textColor = Theme.fg
        label.isEditable = false
        label.isSelectable = false
        label.drawsBackground = false
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Muestra un mensaje con typewriter y lo oculta pasado un rato.
    func say(_ text: String, holdFor: TimeInterval? = nil) {
        typeTimer?.invalidate()
        hideTimer?.invalidate()
        fullText = text
        shown = 0
        label.stringValue = ""
        if commandStyle {
            label.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
            label.textColor = Theme.accent
            layer?.borderColor = Theme.accent.cgColor
            layer?.borderWidth = 1.5
        }
        resizeToFit(text: text)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            animator().alphaValue = 1
        }

        typeTimer = Timer.scheduledTimer(withTimeInterval: 0.018, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            self.shown += 1
            if self.shown >= self.fullText.count {
                self.label.stringValue = self.fullText
                t.invalidate()
                let hold = holdFor ?? min(12, 3 + Double(self.fullText.count) * 0.05)
                self.hideTimer = Timer.scheduledTimer(withTimeInterval: hold, repeats: false) { [weak self] _ in
                    self?.dismiss()
                }
            } else {
                self.label.stringValue = String(self.fullText.prefix(self.shown)) + "▮"
            }
        }
        RunLoop.main.add(typeTimer!, forMode: .common)
    }

    func applyTheme() {
        layer?.borderColor = Theme.accent.withAlphaComponent(0.7).cgColor
        label.textColor = Theme.fg
    }

    // MARK: - Copiar con click

    /// Lo que se copia al hacer click: si el texto lleva comandos entre
    /// backticks, solo los comandos; si no, el texto completo.
    private var copyPayload: String {
        var commands: [String] = []
        var inside = false
        var current = ""
        for ch in fullText {
            if ch == "`" {
                if inside && !current.trimmingCharacters(in: .whitespaces).isEmpty {
                    commands.append(current.trimmingCharacters(in: .whitespaces))
                }
                current = ""
                inside.toggle()
            } else if inside {
                current.append(ch)
            }
        }
        return commands.isEmpty ? fullText : commands.joined(separator: "\n")
    }

    /// Click en el bocadillo: copia el comando (o todo el texto) al portapapeles.
    override func mouseDown(with event: NSEvent) {
        guard !fullText.isEmpty else { return }
        typeTimer?.invalidate()
        hideTimer?.invalidate()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copyPayload, forType: .string)
        label.stringValue = fullText

        // feedback: parpadeo del borde + "copiado"
        layer?.borderColor = Theme.accent.cgColor
        let prev = fullText
        label.stringValue = "copiado ✓"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            self.label.stringValue = prev
            self.layer?.borderColor = Theme.accent.withAlphaComponent(0.7).cgColor
            self.hideTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
                self?.dismiss()
            }
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    func dismiss() {
        typeTimer?.invalidate()
        hideTimer?.invalidate()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            animator().alphaValue = 0
        }
    }

    private func resizeToFit(text: String) {
        let maxWidth: CGFloat = commandStyle ? 620 : 250
        let font = commandStyle ? NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold) : Theme.font(size: 11)
        let attr = NSAttributedString(string: text, attributes: [.font: font])
        let bounds = attr.boundingRect(with: NSSize(width: maxWidth - 20, height: 400),
                                       options: [.usesLineFragmentOrigin, .usesFontLeading])
        let w = min(maxWidth, bounds.width + 24)
        let h = bounds.height + 16
        frame = NSRect(origin: origin(forSize: NSSize(width: w, height: h)),
                       size: NSSize(width: w, height: h))
    }

    /// Recoloca el bocadillo encima del ancla (cuando el monstruo se mueve).
    func follow() {
        setFrameOrigin(origin(forSize: frame.size))
    }

    private func origin(forSize size: NSSize) -> NSPoint {
        guard let sv = superview else { return frame.origin }
        guard let a = anchor else {
            return NSPoint(x: sv.bounds.width - size.width - 12, y: frame.minY)
        }
        var x = a.frame.maxX - size.width           // alineado a la derecha del bicho
        x = max(8, min(sv.bounds.width - size.width - 8, x))
        var y = a.frame.maxY + 6                    // justo encima
        if y + size.height > sv.bounds.height - 34 { // si no cabe, debajo
            y = max(8, a.frame.minY - size.height - 6)
        }
        return NSPoint(x: x, y: y)
    }
}

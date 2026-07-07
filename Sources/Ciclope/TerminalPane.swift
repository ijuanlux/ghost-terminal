import AppKit

// Un panel de terminal con barra de agarre: título, botón de cierre y drag
// para recolocarlo (izquierda, arriba o fuera de la ventana).
final class TerminalPane: NSView {

    enum DragPhase { case moved, ended }

    let session: TerminalSession
    var onDrag: ((TerminalPane, DragPhase, NSPoint) -> Void)?   // punto en pantalla
    var onCloseRequested: ((TerminalPane) -> Void)?

    private let grip = GripBar()

    init(session: TerminalSession) {
        self.session = session
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        wantsLayer = true
        layer?.backgroundColor = Theme.bg.cgColor

        grip.translatesAutoresizingMaskIntoConstraints = false
        addSubview(grip)
        session.view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(session.view)

        NSLayoutConstraint.activate([
            grip.topAnchor.constraint(equalTo: topAnchor),
            grip.leadingAnchor.constraint(equalTo: leadingAnchor),
            grip.trailingAnchor.constraint(equalTo: trailingAnchor),
            grip.heightAnchor.constraint(equalToConstant: 26),
            session.view.topAnchor.constraint(equalTo: grip.bottomAnchor),
            session.view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            session.view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            session.view.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])

        grip.title = session.title
        session.onTitleChange = { [weak self] t in self?.grip.title = t }
        grip.onDrag = { [weak self] phase, screenPoint in
            guard let self else { return }
            self.alphaValue = (phase == .moved) ? 0.55 : 1.0
            self.onDrag?(self, phase, screenPoint)
        }
        grip.onClose = { [weak self] in
            guard let self else { return }
            self.onCloseRequested?(self)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func focus() {
        window?.makeFirstResponder(session.view)
    }

    func applyTheme() {
        layer?.backgroundColor = Theme.bg.cgColor
        grip.applyTheme()
        session.applyTheme()
    }
}

// Barra superior fina: puntito verde + título + ✕, arrastrable.
final class GripBar: NSView {
    var title: String = "" { didSet { label.stringValue = title } }
    var onDrag: ((TerminalPane.DragPhase, NSPoint) -> Void)?
    var onClose: (() -> Void)?

    private let label = NSTextField(labelWithString: "")
    private let closeButton = NSButton(title: "✕", target: nil, action: nil)
    private let dot = NSView()
    private var dragging = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Theme.chromeBg.cgColor

        dot.wantsLayer = true
        dot.layer?.backgroundColor = Theme.accent.cgColor
        dot.layer?.cornerRadius = 3
        dot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dot)

        label.font = Theme.font(size: 10)
        label.textColor = Theme.dimFg
        label.lineBreakMode = .byTruncatingHead
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        // botón de cierre: área tappable amplia (22x22) con ✕ visible y
        // resaltado rojo al pasar el ratón, para que no cueste acertar
        closeButton.isBordered = false
        closeButton.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        closeButton.contentTintColor = Theme.dimFg
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.wantsLayer = true
        closeButton.layer?.cornerRadius = 5
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 7),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -6),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 22),
            closeButton.heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private var closeHover: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let closeHover { removeTrackingArea(closeHover) }
        let area = NSTrackingArea(rect: closeButton.frame,
                                  options: [.mouseEnteredAndExited, .activeAlways],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        closeHover = area
    }

    override func mouseEntered(with event: NSEvent) {
        closeButton.layer?.backgroundColor = NSColor(srgbRed: 0.9, green: 0.25, blue: 0.25, alpha: 0.9).cgColor
        closeButton.contentTintColor = .white
    }

    override func mouseExited(with event: NSEvent) {
        closeButton.layer?.backgroundColor = NSColor.clear.cgColor
        closeButton.contentTintColor = Theme.dimFg
    }

    func applyTheme() {
        layer?.backgroundColor = Theme.chromeBg.cgColor
        dot.layer?.backgroundColor = Theme.accent.cgColor
        label.textColor = Theme.dimFg
        closeButton.contentTintColor = Theme.dimFg
    }

    @objc private func closeTapped() { onClose?() }

    override func mouseDown(with event: NSEvent) { dragging = false }

    override func mouseDragged(with event: NSEvent) {
        dragging = true
        onDrag?(.moved, NSEvent.mouseLocation)
    }

    override func mouseUp(with event: NSEvent) {
        if dragging { onDrag?(.ended, NSEvent.mouseLocation) }
        dragging = false
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }
}

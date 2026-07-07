import AppKit

// Splash de arranque estilo app comercial: ventana flotante pequeña con fondo
// blanco, Ghost aparece con un pop de muelle, suelta su "boo" en una píldora,
// y transición al título ❯ GHOST TERMINAL con subrayado que se dibuja.
// Click = saltar. Toggle en Ajustes.
enum IntroSplash {
    private static var window: NSWindow?

    static func play() {
        guard Prefs.showIntro, window == nil else { return }
        let size = NSSize(width: 520, height: 300)
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let rect = NSRect(x: screen.midX - size.width / 2,
                          y: screen.midY - size.height / 2 + 40,
                          width: size.width, height: size.height)
        let w = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.level = .floating
        w.ignoresMouseEvents = false
        let view = SplashView(frame: NSRect(origin: .zero, size: size))
        view.onDone = { close() }
        w.contentView = view
        w.alphaValue = 0
        window = w
        w.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            w.animator().alphaValue = 1
        }
        view.run()
    }

    private static func close() {
        guard let w = window else { return }
        window = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.45
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            w.animator().alphaValue = 0
        }, completionHandler: {
            w.orderOut(nil)
        })
    }
}

private final class SplashView: NSView {
    var onDone: (() -> Void)?

    private let card = NSView()
    private let ghost = CyclopsView(frame: NSRect(origin: .zero, size: CyclopsView.spriteSize))
    private let skipCatcher = SkipCatcher()
    private let booPill = NSView()
    private let booLabel = NSTextField(labelWithString: "boo")
    private let title = NSTextField(labelWithString: "")
    private let underline = NSView()
    private let subtitle = NSTextField(labelWithString: "")
    private var finished = false

    private let ink = NSColor(srgbRed: 0.09, green: 0.09, blue: 0.11, alpha: 1)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true

        // tarjeta blanca redondeada
        card.frame = bounds
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.white.cgColor
        card.layer?.cornerRadius = 16
        addSubview(card)

        // Ghost VIVO: flota, parpadea y las cadenas ondean con su física
        ghost.layer?.shadowColor = NSColor.black.cgColor
        ghost.layer?.shadowOpacity = 0.15
        ghost.layer?.shadowRadius = 9
        ghost.layer?.shadowOffset = CGSize(width: 0, height: -3)
        ghost.alphaValue = 0
        card.addSubview(ghost)

        // píldora "boo"
        booPill.wantsLayer = true
        booPill.layer?.backgroundColor = ink.cgColor
        booPill.layer?.cornerRadius = 15
        booPill.alphaValue = 0
        booLabel.font = NSFont.monospacedSystemFont(ofSize: 16, weight: .bold)
        booLabel.textColor = .white
        booPill.addSubview(booLabel)
        card.addSubview(booPill)

        // título ❯ GHOST TERMINAL
        let t = NSMutableAttributedString(string: "❯ ", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 26, weight: .bold),
            .foregroundColor: Theme.accent,
        ])
        t.append(NSAttributedString(string: "GHOST TERMINAL", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 26, weight: .bold),
            .foregroundColor: ink,
            .kern: 7,
        ]))
        title.attributedStringValue = t
        title.alphaValue = 0
        card.addSubview(title)

        // subrayado de acento que se dibuja
        underline.wantsLayer = true
        underline.layer?.backgroundColor = Theme.accent.cgColor
        underline.layer?.cornerRadius = 1.5
        underline.alphaValue = 0
        card.addSubview(underline)

        // subtítulo
        subtitle.stringValue = Prefs.language == "en"
            ? "the terminal with a ghost inside"
            : "el terminal con un fantasma dentro"
        subtitle.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        subtitle.textColor = NSColor(white: 0.55, alpha: 1)
        subtitle.alphaValue = 0
        card.addSubview(subtitle)

        layoutContent()

        // capa transparente que captura el click para saltar la intro
        skipCatcher.frame = bounds
        skipCatcher.autoresizingMask = [.width, .height]
        skipCatcher.onClick = { [weak self] in self?.finish() }
        addSubview(skipCatcher, positioned: .above, relativeTo: card)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func layoutContent() {
        let c = NSPoint(x: bounds.midX, y: bounds.midY)
        let gs = CyclopsView.spriteSize
        ghost.setFrameOrigin(NSPoint(x: c.x - gs.width / 2, y: c.y - gs.height / 2 + 16))
        booLabel.sizeToFit()
        let pillW = booLabel.frame.width + 26
        booPill.frame = NSRect(x: ghost.frame.maxX + 10, y: ghost.frame.midY + 16,
                               width: pillW, height: 30)
        booLabel.setFrameOrigin(NSPoint(x: 13, y: (30 - booLabel.frame.height) / 2))

        title.sizeToFit()
        title.setFrameOrigin(NSPoint(x: c.x - title.frame.width / 2, y: c.y - 6))
        underline.frame = NSRect(x: c.x, y: title.frame.minY - 10, width: 0, height: 3)
        subtitle.sizeToFit()
        subtitle.setFrameOrigin(NSPoint(x: c.x - subtitle.frame.width / 2,
                                        y: underline.frame.minY - subtitle.frame.height - 12))
    }

    // MARK: - Secuencia

    func run() {
        after(0.25) { self.pop(self.ghost) }
        after(0.95) {
            self.pop(self.booPill)
            self.shake(self.ghost)
        }
        after(2.1) {
            self.fadeSlide(self.ghost, alpha: 0, dy: 14, duration: 0.35)
            self.fadeSlide(self.booPill, alpha: 0, dy: 14, duration: 0.35)
        }
        after(2.45) {
            self.fadeSlide(self.title, alpha: 1, dy: -10, duration: 0.5)
        }
        after(2.75) {
            self.drawUnderline()
            self.fadeSlide(self.subtitle, alpha: 1, dy: -6, duration: 0.45)
        }
        after(4.4) { self.finish() }
    }

    private func after(_ s: TimeInterval, _ block: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + s) { [weak self] in
            guard let self, !self.finished else { return }
            block()
        }
    }

    /// Pop con muelle: escala 0.4 → 1 con rebote, alrededor del centro.
    private func pop(_ v: NSView) {
        v.alphaValue = 1
        guard let layer = v.layer else { return }
        let center = CGPoint(x: v.frame.midX, y: v.frame.midY)
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.position = center
        let spring = CASpringAnimation(keyPath: "transform.scale")
        spring.fromValue = 0.4
        spring.toValue = 1.0
        spring.damping = 11
        spring.stiffness = 320
        spring.initialVelocity = 6
        spring.duration = spring.settlingDuration
        layer.add(spring, forKey: "pop")
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.18
        layer.add(fade, forKey: "fadein")
    }

    private func fadeSlide(_ v: NSView, alpha: CGFloat, dy: CGFloat, duration: TimeInterval) {
        let target = NSPoint(x: v.frame.origin.x, y: v.frame.origin.y + dy)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            v.animator().alphaValue = alpha
            v.animator().setFrameOrigin(target)
        }
    }

    private func drawUnderline() {
        underline.alphaValue = 1
        let full = title.frame.width * 0.86
        let x = bounds.midX - full / 2
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.5
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            underline.animator().frame = NSRect(x: x, y: underline.frame.minY,
                                                width: full, height: 3)
        }
    }

    private func shake(_ v: NSView) {
        let origin = v.frame.origin
        for (i, dx) in [CGFloat(-3), 3, -2, 2, 0].enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.045) {
                v.setFrameOrigin(NSPoint(x: origin.x + dx, y: origin.y))
            }
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        onDone?()
    }
}

/// Vista transparente que se come el click para saltar la intro.
private final class SkipCatcher: NSView {
    var onClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onClick?() }
}

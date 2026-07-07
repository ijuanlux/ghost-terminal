import AppKit

// Intro cinematográfica al arrancar: negro total, un prompt ❯ parpadeando,
// Ghost aparece y suelta su "boo" con un glitch, y transición al título
// GHOST TERMINAL antes de fundirse revelando el terminal. Click = saltar.
final class IntroView: NSView {

    private let prompt = NSTextField(labelWithString: "❯")
    private let ghost = NSImageView()
    private let boo = NSTextField(labelWithString: "boo")
    private let title = NSTextField(labelWithString: "")
    private var blinkTimer: Timer?
    private var finished = false

    /// Lanza la intro sobre la ventana (si está activada en Ajustes).
    static func play(in window: NSWindow) {
        guard Prefs.showIntro, let content = window.contentView else { return }
        let intro = IntroView(frame: content.bounds)
        intro.autoresizingMask = [.width, .height]
        content.addSubview(intro, positioned: .above, relativeTo: nil)
        intro.run()
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        let mono = NSFont.monospacedSystemFont(ofSize: 40, weight: .medium)

        prompt.font = mono
        prompt.textColor = Theme.accent
        prompt.alphaValue = 0

        ghost.image = CyclopsView.spriteImage(pixel: 6)
        ghost.imageScaling = .scaleNone
        ghost.alphaValue = 0

        boo.font = NSFont.monospacedSystemFont(ofSize: 30, weight: .semibold)
        boo.textColor = .white
        boo.alphaValue = 0

        let t = NSMutableAttributedString(string: "❯ ", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 34, weight: .bold),
            .foregroundColor: Theme.accent,
        ])
        t.append(NSAttributedString(string: "GHOST TERMINAL", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 34, weight: .bold),
            .foregroundColor: NSColor.white,
            .kern: 10,
        ]))
        title.attributedStringValue = t
        title.alphaValue = 0

        for v in [prompt, ghost, boo, title] { addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let c = NSPoint(x: bounds.midX, y: bounds.midY)
        prompt.sizeToFit()
        prompt.setFrameOrigin(NSPoint(x: c.x - prompt.frame.width / 2, y: c.y - prompt.frame.height / 2))
        if let img = ghost.image {
            ghost.frame = NSRect(x: c.x - img.size.width / 2, y: c.y - img.size.height / 2 + 14,
                                 width: img.size.width, height: img.size.height)
        }
        boo.sizeToFit()
        boo.setFrameOrigin(NSPoint(x: ghost.frame.maxX + 14, y: ghost.frame.midY + 8))
        title.sizeToFit()
        title.setFrameOrigin(NSPoint(x: c.x - title.frame.width / 2, y: c.y - title.frame.height / 2))
    }

    private func run() {
        layoutSubtreeIfNeeded()

        // 1) prompt parpadeando en el vacío
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.32, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.prompt.alphaValue = self.prompt.alphaValue > 0.5 ? 0.15 : 1
        }
        RunLoop.main.add(blinkTimer!, forMode: .common)

        // 2) aparece Ghost
        after(0.9) {
            self.blinkTimer?.invalidate()
            self.fade(self.prompt, to: 0, duration: 0.2)
            self.fade(self.ghost, to: 1, duration: 0.45)
        }
        // 3) boo + glitch
        after(1.5) {
            self.fade(self.boo, to: 1, duration: 0.12)
            self.shake(self.ghost)
        }
        // 4) transición al título
        after(2.4) {
            self.fade(self.ghost, to: 0, duration: 0.3)
            self.fade(self.boo, to: 0, duration: 0.3)
        }
        after(2.7) {
            self.fade(self.title, to: 1, duration: 0.55)
            self.drift(self.title, dy: 6, duration: 0.55)
        }
        // 5) fundido final revelando el terminal
        after(4.1) { self.finish() }
    }

    private func after(_ s: TimeInterval, _ block: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + s) { [weak self] in
            guard let self, !self.finished else { return }
            block()
        }
    }

    private func fade(_ v: NSView, to alpha: CGFloat, duration: TimeInterval) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            v.animator().alphaValue = alpha
        }
    }

    private func drift(_ v: NSView, dy: CGFloat, duration: TimeInterval) {
        let target = v.frame.origin
        v.setFrameOrigin(NSPoint(x: target.x, y: target.y - dy))
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            v.animator().setFrameOrigin(target)
        }
    }

    private func shake(_ v: NSView) {
        let origin = v.frame.origin
        let offsets: [CGFloat] = [-4, 4, -2, 2, 0]
        for (i, dx) in offsets.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.05) {
                v.setFrameOrigin(NSPoint(x: origin.x + dx, y: origin.y))
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        finish()
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        blinkTimer?.invalidate()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.5
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.removeFromSuperview()
        })
    }
}

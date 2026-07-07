import AppKit
import SwiftTerm

// Barra de scroll propia: track fino a la derecha del terminal con tirador
// del color de acento. Dos modos:
//  - absoluta: shell normal con scrollback, el tirador refleja la posición
//  - palanca: apps a pantalla completa con ratón (claude, htop): el tirador
//    vive centrado y arrastrarlo manda eventos de rueda; al soltar, vuelve
final class GhostScrollBar: NSView {
    weak var terminalView: CiclopeTerminalView?

    private enum Mode { case absolute, joystick }
    private var mode: Mode = .absolute
    private var timer: Timer?
    private var dragging = false
    private var joyOffset: CGFloat = 0
    private var lastDragY: CGFloat?
    private var wheelAccum: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.sync()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    required init?(coder: NSCoder) { fatalError() }
    deinit { timer?.invalidate() }

    private func sync() {
        guard let tv = terminalView else { return }
        let t = tv.getTerminal()
        var visible = false
        if tv.canScroll {
            mode = .absolute
            visible = true
        } else if t.isCurrentBufferAlternate {
            let mouseOn: Bool
            switch t.mouseMode {
            case .off: mouseOn = false
            default: mouseOn = true
            }
            if mouseOn {
                mode = .joystick
                visible = true
            }
        }
        if isHidden == visible { isHidden = !visible }
        if visible && !dragging { needsDisplay = true }
    }

    private var knobHeight: CGFloat { max(28, bounds.height * 0.12) }

    private func knobRect() -> NSRect {
        let track = bounds.insetBy(dx: 2, dy: 4)
        let travel = track.height - knobHeight
        switch mode {
        case .absolute:
            guard let tv = terminalView else { return .zero }
            let p = CGFloat(max(0, min(1, tv.scrollPosition)))
            let y = track.maxY - p * travel - knobHeight
            return NSRect(x: track.minX, y: y, width: track.width, height: knobHeight)
        case .joystick:
            let center = track.midY - knobHeight / 2
            let y = max(track.minY, min(track.maxY - knobHeight, center + joyOffset))
            return NSRect(x: track.minX, y: y, width: track.width, height: knobHeight)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.chromeBg.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 3, yRadius: 3).fill()
        let alpha: CGFloat = dragging ? 1.0 : 0.75
        Theme.accent.withAlphaComponent(alpha).setFill()
        NSBezierPath(roundedRect: knobRect(), xRadius: 3, yRadius: 3).fill()
        if mode == .joystick {
            // muescas arriba/abajo del tirador: pista de que es una palanca
            Theme.accent.withAlphaComponent(0.35).setFill()
            let k = knobRect()
            ctxDot(x: k.midX, y: k.maxY + 7)
            ctxDot(x: k.midX, y: k.minY - 7)
        }
    }

    private func ctxDot(x: CGFloat, y: CGFloat) {
        NSBezierPath(ovalIn: NSRect(x: x - 1.5, y: y - 1.5, width: 3, height: 3)).fill()
    }

    // MARK: - Interacción

    private func scrollAbsolute(to point: NSPoint) {
        guard let tv = terminalView else { return }
        let track = bounds.insetBy(dx: 2, dy: 4)
        let travel = track.height - knobHeight
        guard travel > 0 else { return }
        let p = (track.maxY - point.y - knobHeight / 2) / travel
        tv.scroll(toPosition: Double(max(0, min(1, p))))
        needsDisplay = true
    }

    private func joystickDrag(to point: NSPoint) {
        guard let tv = terminalView else { return }
        let t = tv.getTerminal()
        if let last = lastDragY {
            wheelAccum += last - point.y   // positivo = arrastrando hacia abajo
            let steps = Int(wheelAccum / 9)
            if steps != 0 {
                wheelAccum -= CGFloat(steps) * 9
                let button = steps > 0 ? 65 : 64   // abajo / arriba
                for _ in 0..<min(abs(steps), 5) {
                    t.sendEvent(buttonFlags: button, x: t.cols / 2, y: t.rows / 2)
                }
            }
        }
        lastDragY = point.y
        let track = bounds.insetBy(dx: 2, dy: 4)
        joyOffset = point.y - track.midY
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        dragging = true
        let p = convert(event.locationInWindow, from: nil)
        lastDragY = p.y
        wheelAccum = 0
        if mode == .absolute { scrollAbsolute(to: p) }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        switch mode {
        case .absolute: scrollAbsolute(to: p)
        case .joystick: joystickDrag(to: p)
        }
    }

    override func mouseUp(with event: NSEvent) {
        dragging = false
        lastDragY = nil
        joyOffset = 0
        needsDisplay = true
    }
}

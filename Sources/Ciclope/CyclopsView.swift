import AppKit

// Ghost: fantasmita pixel art de un solo ojo que flota sobre el terminal.
// La pupila sigue al ratón, parpadea, ondea al flotar, arrastra cadenas con
// física de verdad y suelta glitches. Arrastrable; click = resumen de sesión.
final class CyclopsView: NSView {

    enum Face {
        case normal
        case error    // pupila roja + ceño
        case sleepy   // ojo cerrado + z
        case thinking // pupila orbitando + ruedita
        case party    // bote + brillo
    }

    var face: Face = .normal { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?
    var onMoved: (() -> Void)?
    var onDropped: ((NSPoint) -> Void)?   // punto en pantalla al soltar tras arrastre

    private var dragStart: NSPoint?
    private var didDrag = false

    private static let pixel: CGFloat = 3
    private static let xPad: CGFloat = 22   // margen para cadenas y paseillo lateral
    private let scale: CGFloat = CyclopsView.pixel
    private var phase: CGFloat = 0
    private var blinkUntil = Date.distantPast
    private var nextBlink = Date().addingTimeInterval(3)
    private var glitchFrames = 0
    private var nextGlitch = Date().addingTimeInterval(8)
    private var followX: CGFloat = 0
    private var followY: CGFloat = 0
    private var timer: Timer?

    // gestos espontáneos de idle
    private enum Gesture { case none, flip, hop, look }
    private var gesture: Gesture = .none
    private var gestureUntil = Date.distantPast
    private var nextGesture = Date().addingTimeInterval(12)

    // cadenas con física Verlet (coordenadas del superview, para que sientan
    // el movimiento del fantasma al arrastrarlo y el suelo de la ventana)
    private struct ChainNode { var p: CGPoint; var old: CGPoint }
    private var chains: [[ChainNode]] = []
    private let chainNodes = 11
    private var chainSpacing: CGFloat { scale * 1.8 }

    // Paleta fantasma
    private static let outline = NSColor(srgbRed: 0.08, green: 0.08, blue: 0.12, alpha: 1)
    private static let body    = NSColor(srgbRed: 0.95, green: 0.95, blue: 0.98, alpha: 1)
    private static let shade   = NSColor(srgbRed: 0.78, green: 0.80, blue: 0.88, alpha: 1)
    private static let eyeW    = NSColor.white
    private static let pupilC  = NSColor(srgbRed: 0.08, green: 0.08, blue: 0.12, alpha: 1)
    private static let angryC  = NSColor(srgbRed: 0.85, green: 0.15, blue: 0.12, alpha: 1)
    private static let metal   = NSColor(srgbRed: 0.66, green: 0.69, blue: 0.76, alpha: 1)
    private static let metalD  = NSColor(srgbRed: 0.42, green: 0.44, blue: 0.52, alpha: 1)

    // 24 x 22 celdas. K contorno, W cuerpo, w sombra, E interior del ojo
    private static let grid: [String] = [
        ".........KKKKKK.........",
        ".......KKWWWWWWKK.......",
        "......KWWWWWWWWWWK......",
        ".....KWWWWWWWWWWWWK.....",
        "....KWWWWWWWWWWWWWWK....",
        "....KWWWKKEEEEKKWWWK....",
        "...KWWWKEEEEEEEEKWWWK...",
        "...KWWWKEEEEEEEEKWWWK...",
        "...KWWWKEEEEEEEEKWWWK...",
        "...KWWWWKKEEEEKKWWWWK...",
        "...KWWWWWWKKKKWWWWWWK...",
        "..KWWWWWWWWWWWWWWWWWWK..",
        "..KWWWWWWWWWWWWWWWWWWK..",
        "..KWwWWWWWWWWWWWWWWwWK..",
        "..KWwWWWWWWWWWWWWWWwWK..",
        "..KWwWWWWWWWWWWWWWWwWK..",
        "..KWwwWWWWWWWWWWWWwwWK..",
        "..KWwwWWWWWWWWWWWWwwWK..",
        "..KWwwWWWWWWWWWWWWwwWK..",
        "..KWwWWWWWWWWWWWWWWwWK..",
        "..KWWWWKWWWWKKWWWWKWWK..",
        "...KKKK.KKKK..KKKK.KK...",
    ]

    private static let eyeCols = 8...15
    private static let eyeRows = 5...9

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.shadowColor = NSColor(srgbRed: 0.75, green: 0.85, blue: 1.0, alpha: 1).cgColor
        layer?.shadowOpacity = 0.45
        layer?.shadowRadius = 9
        layer?.shadowOffset = .zero
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    required init?(coder: NSCoder) { fatalError() }
    deinit { timer?.invalidate() }

    static var spriteSize: NSSize {
        NSSize(width: CGFloat(grid[0].count) * pixel + xPad * 2,
               height: CGFloat(grid.count) * pixel + 44)
    }

    /// Susto: ráfaga de glitches mientras cuenta la historia.
    func spook() {
        glitchFrames = 14
    }

    func lookToward(windowPoint: NSPoint) {
        guard let sp = superview?.convert(windowPoint, from: nil) else { return }
        let center = NSPoint(x: frame.midX, y: frame.midY)
        followX = max(-1, min(1, (sp.x - center.x) / 260))
        followY = max(-1, min(1, (sp.y - center.y) / 260))
    }

    /// Movimiento actual del cuerpo (compartido entre dibujo y física).
    private var motion: (baseY: CGFloat, sway: CGFloat) {
        var bobAmp: CGFloat = (face == .party) ? 7 : 4
        if gesture == .hop { bobAmp = 9 }
        let bob = (gesture == .hop ? sin(phase * 3.2) : sin(phase)) * bobAmp
        // pensando: paseillo lateral, y las cadenas hacen pendulo por la fisica
        // tanh endurece el seno: pausa breve en cada lado y arranque brusco
        // hacia el otro, para que las cadenas den el latigazo
        let sway = face == .thinking
            ? tanh(sin(phase * 0.9) * 3.2) * 16
            : sin(phase * 0.55) * 3.5
        return (14 + bob, sway)
    }

    private func tick() {
        phase += 0.05
        let now = Date()
        if now > nextBlink {
            blinkUntil = now.addingTimeInterval(0.14)
            nextBlink = now.addingTimeInterval(Double.random(in: 2.5...6))
        }
        if glitchFrames > 0 { glitchFrames -= 1 }
        else if now > nextGlitch {
            glitchFrames = 3
            nextGlitch = now.addingTimeInterval(Double.random(in: 7...16))
        }
        if now > gestureUntil { gesture = .none }
        if face == .normal, gesture == .none, now > nextGesture {
            gesture = [.flip, .hop, .look].randomElement()!
            gestureUntil = now.addingTimeInterval(gesture == .look ? 1.8 : 1.0)
            nextGesture = now.addingTimeInterval(Double.random(in: 14...30))
        }
        stepChains()
        needsDisplay = true
    }

    // MARK: - Física de cadenas

    /// Anclajes (costados del cuerpo) en coordenadas del superview.
    private func chainAnchors() -> [CGPoint] {
        let m = motion
        let rows = CGFloat(Self.grid.count)
        let ay = (rows - 14) * scale + m.baseY
        return [
            CGPoint(x: frame.minX + Self.xPad + 1.0 * scale + m.sway, y: frame.minY + ay),
            CGPoint(x: frame.minX + Self.xPad + 23.0 * scale + m.sway, y: frame.minY + ay),
        ]
    }

    private func stepChains() {
        guard superview != nil else { return }
        let anchors = chainAnchors()
        if chains.count != anchors.count {
            chains = anchors.map { a in
                (0..<chainNodes).map { i in
                    let p = CGPoint(x: a.x, y: a.y - CGFloat(i) * chainSpacing)
                    return ChainNode(p: p, old: p)
                }
            }
        }
        let floorY: CGFloat = 6   // suelo: borde inferior de la ventana
        for c in chains.indices {
            chains[c][0].p = anchors[c]
            chains[c][0].old = anchors[c]
            for i in 1..<chainNodes {
                var n = chains[c][i]
                let vx = (n.p.x - n.old.x) * 0.94
                let vy = (n.p.y - n.old.y) * 0.94
                n.old = n.p
                n.p.x += vx + sin(phase * 0.8 + CGFloat(i) * 0.5 + CGFloat(c) * 2) * 0.12
                n.p.y += vy - 2.1   // gravedad
                if n.p.y < floorY {
                    n.p.y = floorY
                    n.p.x -= vx * 0.55   // fricción con el suelo
                }
                chains[c][i] = n
            }
            // restricciones de distancia entre eslabones (3 pasadas)
            for _ in 0..<3 {
                chains[c][0].p = anchors[c]
                for i in 0..<(chainNodes - 1) {
                    let a = chains[c][i].p
                    let b = chains[c][i + 1].p
                    let dx = b.x - a.x
                    let dy = b.y - a.y
                    let dist = max(0.001, sqrt(dx * dx + dy * dy))
                    let diff = (dist - chainSpacing) / dist
                    if i == 0 {
                        chains[c][i + 1].p.x -= dx * diff
                        chains[c][i + 1].p.y -= dy * diff
                    } else {
                        chains[c][i].p.x += dx * diff * 0.5
                        chains[c][i].p.y += dy * diff * 0.5
                        chains[c][i + 1].p.x -= dx * diff * 0.5
                        chains[c][i + 1].p.y -= dy * diff * 0.5
                    }
                }
            }
        }
    }

    // MARK: - Arrastrable (y click = resumen)

    override func mouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil)
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart, let sv = superview else { return }
        didDrag = true
        let p = sv.convert(event.locationInWindow, from: nil)
        var origin = NSPoint(x: p.x - dragStart.x, y: p.y - dragStart.y)
        origin.x = max(0, min(sv.bounds.width - frame.width, origin.x))
        origin.y = max(0, min(sv.bounds.height - frame.height - 30, origin.y))
        setFrameOrigin(origin)
        onMoved?()
    }

    override func mouseUp(with event: NSEvent) {
        if didDrag, let sv = superview {
            UserDefaults.standard.set(sv.bounds.width - frame.maxX, forKey: "ciclope.dx")
            UserDefaults.standard.set(frame.minY, forKey: "ciclope.dy")
            onDropped?(NSEvent.mouseLocation)
        } else {
            onClick?()
        }
        dragStart = nil
        didDrag = false
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    static var savedOffset: (dx: CGFloat, dy: CGFloat) {
        let d = UserDefaults.standard
        let dx = d.object(forKey: "ciclope.dx") as? CGFloat ?? 24
        let dy = d.object(forKey: "ciclope.dy") as? CGFloat ?? 16
        return (max(0, dx), max(0, dy))
    }

    // MARK: - Dibujo

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setShouldAntialias(false)

        let rows = Self.grid.count
        let cols = Self.grid[0].count
        let m = motion
        let baseY = m.baseY
        let sway = m.sway
        let blinking = Date() < blinkUntil || face == .sleepy

        drawChains()

        for (r, line) in Self.grid.enumerated() {
            var gx: CGFloat = 0
            if glitchFrames > 0 && r % 3 == Int(phase * 10) % 3 {
                gx = CGFloat(Int.random(in: -2...2))
            }
            var waveX: CGFloat = 0
            if r >= rows - 4 {
                waveX = (sin(phase * 2 + CGFloat(r)) * 1.5).rounded()
            }
            for (cIdx, ch) in line.enumerated() {
                let color: NSColor?
                switch ch {
                case "K": color = Self.outline
                case "W": color = Self.body
                case "w": color = Self.shade
                case "E": color = blinking ? Self.body : Self.eyeW
                default:  color = nil
                }
                guard let color else { continue }
                color.setFill()
                let col = gesture == .flip ? (cols - 1 - cIdx) : cIdx
                let x = Self.xPad + CGFloat(col) * scale + gx + sway + waveX
                let y = CGFloat(rows - 1 - r) * scale + baseY
                ctx.fill(CGRect(x: x, y: y, width: scale, height: scale))
            }
        }

        drawEyeDetail(ctx: ctx, rows: rows, baseY: baseY, sway: sway, blinking: blinking)

        if face == .sleepy {
            drawZ(ctx: ctx, rows: rows, baseY: baseY)
        }
        if face == .thinking {
            drawSpinner(ctx: ctx, rows: rows, baseY: baseY, sway: sway)
        }
    }

    /// Cadenas: eslabones rotados siguiendo la curva, alternando eslabón plano
    /// (aro hueco) y eslabón de canto (barra fina), como una cadena de verdad.
    private func drawChains() {
        guard !chains.isEmpty, let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.setShouldAntialias(true)   // los aros rotados lo agradecen
        for chain in chains {
            for i in 0..<(chainNodes - 1) {
                let a = chain[i].p
                let b = chain[i + 1].p
                let mx = (a.x + b.x) / 2 - frame.minX
                let my = (a.y + b.y) / 2 - frame.minY
                let angle = atan2(b.y - a.y, b.x - a.x)
                ctx.saveGState()
                ctx.translateBy(x: mx, y: my)
                ctx.rotate(by: angle)
                if i % 2 == 0 {
                    // eslabón plano: aro hueco a lo largo del segmento
                    let len = chainSpacing * 1.55
                    let w = scale * 2.0
                    let rect = CGRect(x: -len / 2, y: -w / 2, width: len, height: w)
                    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: w / 2, cornerHeight: w / 2, transform: nil))
                    ctx.setLineWidth(scale * 0.85)
                    ctx.setStrokeColor(Self.metal.cgColor)
                    ctx.strokePath()
                } else {
                    // eslabón de canto: barra fina que une los aros
                    let len = chainSpacing * 1.1
                    let w = scale * 0.9
                    let rect = CGRect(x: -len / 2, y: -w / 2, width: len, height: w)
                    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: w / 2, cornerHeight: w / 2, transform: nil))
                    ctx.setFillColor(Self.metalD.cgColor)
                    ctx.fillPath()
                }
                ctx.restoreGState()
            }
        }
        ctx.restoreGState()
    }

    private func drawEyeDetail(ctx: CGContext, rows: Int, baseY: CGFloat, sway: CGFloat, blinking: Bool) {
        let eyeX = Self.xPad + CGFloat(Self.eyeCols.lowerBound) * scale + sway
        let eyeY = CGFloat(rows - 1 - Self.eyeRows.upperBound) * scale + baseY
        let eyeW = CGFloat(Self.eyeCols.count) * scale
        let eyeH = CGFloat(Self.eyeRows.count) * scale

        if blinking {
            Self.outline.setFill()
            ctx.fill(CGRect(x: eyeX + scale, y: eyeY + eyeH / 2 - scale / 2,
                            width: eyeW - scale * 2, height: scale))
            return
        }

        var px = followX
        var py = followY
        if face == .thinking {
            px = cos(phase * 2.2)
            py = sin(phase * 2.2)
        } else if gesture == .look {
            px = sin(phase * 3.5) * 1.2
            py = 0.2
        } else if gesture == .flip {
            px = -px
        }
        let pupilColor = (face == .error) ? Self.angryC : Self.pupilC
        pupilColor.setFill()
        let cx = eyeX + eyeW / 2 - scale + (px * 1.5 * scale).rounded()
        let cy = eyeY + eyeH / 2 - scale + (py * scale).rounded()
        ctx.fill(CGRect(x: cx, y: cy, width: scale * 2, height: scale * 2))

        if face == .party {
            Self.eyeW.setFill()
            ctx.fill(CGRect(x: cx + scale * 1.2, y: cy + scale * 1.2,
                            width: scale * 0.8, height: scale * 0.8))
        }

        if face == .error {
            Self.outline.setFill()
            let n = Self.eyeCols.count
            for i in 0..<n {
                let drop = CGFloat(min(i, n - 1 - i))
                ctx.fill(CGRect(x: eyeX + CGFloat(i) * scale,
                                y: eyeY + eyeH - scale - drop * scale * 0.4,
                                width: scale, height: scale))
            }
        }
    }

    /// Ruedita de carga pixel art (8 puntos con estela) sobre la cabeza.
    private func drawSpinner(ctx: CGContext, rows: Int, baseY: CGFloat, sway: CGFloat) {
        let cx = Self.xPad + 12 * scale + sway
        let cy = CGFloat(rows) * scale + baseY + 9
        let radius = 2.6 * scale
        let head = Int(phase * 9) % 8
        for i in 0..<8 {
            let angle = CGFloat(i) * .pi / 4
            let dist = (head - i + 8) % 8
            let alpha = max(0.12, 1.0 - CGFloat(dist) * 0.13)
            NSColor.white.withAlphaComponent(alpha).setFill()
            let x = cx + cos(angle) * radius - scale / 2
            let y = cy + sin(angle) * radius - scale / 2
            ctx.fill(CGRect(x: x.rounded(), y: y.rounded(), width: scale, height: scale))
        }
    }

    private func drawZ(ctx: CGContext, rows: Int, baseY: CGFloat) {
        let zGrid = ["xxx", "..x", ".x.", "x..", "xxx"]
        NSColor.white.withAlphaComponent(0.85).setFill()
        let px = scale * 0.7
        let wob = sin(phase * 1.5) * 2
        for (zi, zScale) in [(0, 1.0), (1, 0.7)] {
            let ox = Self.xPad + CGFloat(18 + zi * 4) * scale + wob
            let oy = CGFloat(rows) * scale + baseY - CGFloat(zi) * 6 + CGFloat(zi) * 10
            for (r, line) in zGrid.enumerated() {
                for (c, ch) in line.enumerated() where ch == "x" {
                    ctx.fill(CGRect(x: ox + CGFloat(c) * px * zScale,
                                    y: oy + CGFloat(zGrid.count - 1 - r) * px * zScale,
                                    width: px * zScale, height: px * zScale))
                }
            }
        }
    }
}

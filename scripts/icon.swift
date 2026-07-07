// Renderiza a Ghost (fantasmita pixel) a PNG 1024x1024 para el icono de la app.
// Uso: swift icon.swift /ruta/salida.png
import AppKit

let outline = NSColor(srgbRed: 0.08, green: 0.08, blue: 0.12, alpha: 1)
let bodyC   = NSColor(srgbRed: 0.95, green: 0.95, blue: 0.98, alpha: 1)
let shade   = NSColor(srgbRed: 0.78, green: 0.80, blue: 0.88, alpha: 1)
let eyeW    = NSColor.white

// Mismo sprite que CyclopsView
let grid: [String] = [
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

let size = 1024
let cols = grid[0].count
let rows = grid.count
let cell = (CGFloat(size) * 0.80) / CGFloat(max(cols, rows))
let offX = (CGFloat(size) - cell * CGFloat(cols)) / 2
let offY = (CGFloat(size) - cell * CGFloat(rows)) / 2

let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
ctx.setShouldAntialias(false)

// fondo redondeado oscuro con borde verde suave (estética de la app)
let bg = NSColor(srgbRed: 0.012, green: 0.024, blue: 0.016, alpha: 1)
let accent = NSColor(srgbRed: 0.22, green: 1.0, blue: 0.48, alpha: 1)
let r = NSBezierPath(roundedRect: NSRect(x: 60, y: 60, width: size - 120, height: size - 120),
                     xRadius: 180, yRadius: 180)
bg.setFill(); r.fill()
accent.withAlphaComponent(0.35).setStroke(); r.lineWidth = 8; r.stroke()

for (rI, line) in grid.enumerated() {
    for (cI, ch) in line.enumerated() {
        let color: NSColor?
        switch ch {
        case "K": color = outline
        case "W": color = bodyC
        case "w": color = shade
        case "E": color = eyeW
        default:  color = nil
        }
        guard let color else { continue }
        color.setFill()
        ctx.fill(CGRect(x: offX + CGFloat(cI) * cell,
                        y: offY + CGFloat(rows - 1 - rI) * cell,
                        width: cell, height: cell))
    }
}

// pupila centrada en el ojo (cols 8-15, filas 5-9)
outline.setFill()
let pupilX = offX + 11 * cell
let pupilY = offY + CGFloat(rows - 1 - 8) * cell
ctx.fill(CGRect(x: pupilX, y: pupilY, width: cell * 2, height: cell * 2))

img.unlockFocus()

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let tiff = img.tiffRepresentation!
let rep = NSBitmapImageRep(data: tiff)!
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: out))
print("icono en \(out)")

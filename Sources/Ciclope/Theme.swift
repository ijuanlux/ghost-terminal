import AppKit
import SwiftTerm

// Paleta de colores de un tema completo (UI + 16 colores ANSI del terminal).
struct Palette {
    let name: String
    let bg: NSColor        // fondo del terminal y la ventana
    let fg: NSColor        // texto principal
    let dimFg: NSColor     // texto secundario
    let accent: NSColor    // acento (activo, bordes, cursor)
    let danger: NSColor
    let chromeBg: NSColor  // fondo de sidebar y grip bars
    let divider: NSColor
    let ansi: [SwiftTerm.Color]
}

// Tema activo, conmutable en caliente. Los componentes leen Theme.bg, Theme.fg...
// que proxean a la paleta actual; al cambiar se emite .changed y las vistas
// existentes se re-aplican.
enum Theme {
    static let changed = Notification.Name("GhostThemeChanged")

    private(set) static var current: Palette = hacker

    static let all: [Palette] = [hacker, oldSchool, cloud, it, geek, apple, windows, linux]

    static func restore() {
        let env = ProcessInfo.processInfo.environment["CICLOPE_THEME"]
        let saved = env ?? UserDefaults.standard.string(forKey: "ghost.theme")
        if let saved, let p = all.first(where: { $0.name == saved }) {
            current = p
        }
    }

    static func select(_ name: String) {
        guard let p = all.first(where: { $0.name == name }) else { return }
        current = p
        UserDefaults.standard.set(name, forKey: "ghost.theme")
        NotificationCenter.default.post(name: changed, object: nil)
    }

    // MARK: - Proxies (los componentes usan esto)

    static var bg: NSColor { current.bg }
    static var fg: NSColor { current.fg }
    static var dimFg: NSColor { current.dimFg }
    static var accent: NSColor { current.accent }
    static var danger: NSColor { current.danger }
    static var chromeBg: NSColor { current.chromeBg }
    static var divider: NSColor { current.divider }
    static var ansi: [SwiftTerm.Color] { current.ansi }

    static func font(size: CGFloat) -> NSFont {
        for name in ["JetBrainsMono Nerd Font Mono", "JetBrains Mono", "FiraCode Nerd Font Mono", "SF Mono"] {
            if let f = NSFont(name: name, size: size) { return f }
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    // MARK: - Helpers

    private static func n(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    private static func c(_ hex: UInt32) -> SwiftTerm.Color {
        let r = UInt16((hex >> 16) & 0xFF), g = UInt16((hex >> 8) & 0xFF), b = UInt16(hex & 0xFF)
        return SwiftTerm.Color(red: r &* 257, green: g &* 257, blue: b &* 257)
    }

    // MARK: - Temas

    /// Fósforo verde sobre negro. El de siempre.
    static let hacker = Palette(
        name: "Hacker",
        bg: n(0x030603), fg: n(0xB8FFC8), dimFg: n(0x598C66),
        accent: n(0x38FF7A), danger: n(0xFF5454),
        chromeBg: n(0x07120B), divider: n(0x0F2417),
        ansi: [
            c(0x0A130D), c(0xE05561), c(0x38FF7A), c(0xC8E64C),
            c(0x5CC9B0), c(0x8AE0A0), c(0x4CE6C8), c(0xB8FFC8),
            c(0x2E4A38), c(0xFF7A85), c(0x7AFFA8), c(0xE6FF7A),
            c(0x8AE0D0), c(0xB0FFC0), c(0x7AFFE6), c(0xEFFFF2),
        ])

    /// Ámbar CRT, monitor de los 80.
    static let oldSchool = Palette(
        name: "Old School",
        bg: n(0x120C02), fg: n(0xFFC66E), dimFg: n(0x8A6A30),
        accent: n(0xFFB000), danger: n(0xFF5533),
        chromeBg: n(0x1A1206), divider: n(0x33240A),
        ansi: [
            c(0x1A1000), c(0xE0603A), c(0xC8A031), c(0xFFD75F),
            c(0xD08A2C), c(0xE0A050), c(0xF0C060), c(0xFFC66E),
            c(0x5C4418), c(0xFF7A50), c(0xE6C050), c(0xFFE68A),
            c(0xF0AA40), c(0xFFC070), c(0xFFD890), c(0xFFEFC2),
        ])

    /// Azules navy, rollo consola de nube.
    static let cloud = Palette(
        name: "Cloud",
        bg: n(0x0A111E), fg: n(0xD6E4F5), dimFg: n(0x5C7590),
        accent: n(0x4FA8FF), danger: n(0xFF6B6B),
        chromeBg: n(0x0E1728), divider: n(0x1C2C45),
        ansi: [
            c(0x101825), c(0xE06C75), c(0x50C878), c(0xE5C07B),
            c(0x569CD6), c(0xB48EAD), c(0x4EC9B0), c(0xD6E4F5),
            c(0x3A4E68), c(0xFF8A93), c(0x7AE09A), c(0xFFD98A),
            c(0x82BFFF), c(0xD0A8DD), c(0x6EE0D0), c(0xF0F6FF),
        ])

    /// Gris azulado corporativo, sobrio, rollo ops.
    static let it = Palette(
        name: "IT",
        bg: n(0x0F1215), fg: n(0xE0E4E8), dimFg: n(0x707A85),
        accent: n(0x5CA8DD), danger: n(0xE74856),
        chromeBg: n(0x161B20), divider: n(0x272E36),
        ansi: [
            c(0x14181C), c(0xC50F1F), c(0x13A10E), c(0xC19C00),
            c(0x3B78FF), c(0x881798), c(0x3A96DD), c(0xCCCCCC),
            c(0x4D5760), c(0xE74856), c(0x16C60C), c(0xF9F1A5),
            c(0x60A5FA), c(0xB4009E), c(0x61D6D6), c(0xF2F2F2),
        ])

    /// Gris grafito estilo Terminal.app, azul sistema de macOS.
    static let apple = Palette(
        name: "Apple",
        bg: n(0x1B1B1E), fg: n(0xE8E8ED), dimFg: n(0x86868B),
        accent: n(0x0A84FF), danger: n(0xFF453A),
        chromeBg: n(0x232326), divider: n(0x3A3A3E),
        ansi: [
            c(0x1B1B1E), c(0xFF453A), c(0x32D74B), c(0xFFD60A),
            c(0x0A84FF), c(0xBF5AF2), c(0x64D2FF), c(0xE8E8ED),
            c(0x58585E), c(0xFF6961), c(0x6EE787), c(0xFFE97A),
            c(0x64A8FF), c(0xD68AFF), c(0x8AE0FF), c(0xF5F5F7),
        ])

    /// Azul PowerShell con la paleta Campbell de Windows Terminal.
    static let windows = Palette(
        name: "Windows",
        bg: n(0x012456), fg: n(0xEEEDF0), dimFg: n(0x7A8FB5),
        accent: n(0x00BCF2), danger: n(0xE74856),
        chromeBg: n(0x011B42), divider: n(0x0A3A78),
        ansi: [
            c(0x0C0C0C), c(0xC50F1F), c(0x13A10E), c(0xC19C00),
            c(0x3B78FF), c(0x881798), c(0x3A96DD), c(0xCCCCCC),
            c(0x767676), c(0xE74856), c(0x16C60C), c(0xF9F1A5),
            c(0x60A5FA), c(0xB4009E), c(0x61D6D6), c(0xF2F2F2),
        ])

    /// Berenjena Ubuntu con naranja y la paleta Tango.
    static let linux = Palette(
        name: "Linux",
        bg: n(0x300A24), fg: n(0xEEEEEC), dimFg: n(0x9A7C90),
        accent: n(0xE95420), danger: n(0xEF2929),
        chromeBg: n(0x260820), divider: n(0x4E1B40),
        ansi: [
            c(0x2E3436), c(0xCC0000), c(0x4E9A06), c(0xC4A000),
            c(0x3465A4), c(0x75507B), c(0x06989A), c(0xD3D7CF),
            c(0x555753), c(0xEF2929), c(0x8AE234), c(0xFCE94F),
            c(0x729FCF), c(0xAD7FA8), c(0x34E2E2), c(0xEEEEEC),
        ])

    /// Synthwave púrpura y neón, geek total.
    static let geek = Palette(
        name: "Geek",
        bg: n(0x120821), fg: n(0xEAD9FF), dimFg: n(0x7A5C99),
        accent: n(0xFF3CAC), danger: n(0xFF5555),
        chromeBg: n(0x1A0D2E), divider: n(0x321C52),
        ansi: [
            c(0x1A1028), c(0xFF5C8A), c(0x3CFFB4), c(0xFFE066),
            c(0x7A6CFF), c(0xFF3CAC), c(0x00E5FF), c(0xEAD9FF),
            c(0x503A70), c(0xFF8AAC), c(0x8AFFD0), c(0xFFF0A0),
            c(0xA89CFF), c(0xFF7AC8), c(0x7AF0FF), c(0xF8F0FF),
        ])
}

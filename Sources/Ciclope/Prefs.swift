import Foundation

// Preferencias persistentes de la app (UserDefaults) + idioma.
enum Prefs {
    static let changed = Notification.Name("GhostPrefsChanged")
    private static var d: UserDefaults { .standard }

    /// "es" o "en"
    static var language: String {
        get { d.string(forKey: "ghost.lang") ?? "es" }
        set { d.set(newValue, forKey: "ghost.lang"); NotificationCenter.default.post(name: changed, object: nil) }
    }

    static var fontSize: CGFloat {
        get { d.object(forKey: "ghost.fontSize") as? CGFloat ?? 13 }
        set { d.set(newValue, forKey: "ghost.fontSize") }
    }

    static var showBanner: Bool {
        get { d.object(forKey: "ghost.banner") as? Bool ?? true }
        set { d.set(newValue, forKey: "ghost.banner") }
    }

    /// Resúmenes automáticos de Ghost con el LLM (cada N comandos / minutos)
    static var aiSummaries: Bool {
        get { d.object(forKey: "ghost.aiSummaries") as? Bool ?? true }
        set { d.set(newValue, forKey: "ghost.aiSummaries") }
    }

    /// Acciones de boo: ejecutar en el terminal los scripts que genera el LLM
    static var booActions: Bool {
        get { d.object(forKey: "ghost.actions") as? Bool ?? true }
        set { d.set(newValue, forKey: "ghost.actions") }
    }
}

// Textos de la interfaz en español e inglés. La UI se construye por código,
// así que localizamos con una tabla propia y reconstruimos al cambiar idioma.
enum L {
    static func t(_ key: String) -> String {
        (Prefs.language == "en" ? en[key] : es[key]) ?? es[key] ?? key
    }

    private static let es: [String: String] = [
        "menu.about": "Acerca de Ghost",
        "menu.settings": "Ajustes…",
        "menu.hide": "Ocultar Ghost",
        "menu.quit": "Salir de Ghost",
        "menu.shell": "Shell",
        "menu.newTab": "Nueva pestaña",
        "menu.split": "Dividir terminal (izquierda)",
        "menu.newWindow": "Nueva ventana",
        "menu.close": "Cerrar",
        "menu.edit": "Edición",
        "menu.copy": "Copiar",
        "menu.paste": "Pegar",
        "menu.selectAll": "Seleccionar todo",
        "menu.view": "Vista",
        "menu.fontBigger": "Aumentar fuente",
        "menu.fontSmaller": "Reducir fuente",
        "menu.theme": "Tema",
        "menu.toggleGhost": "Mostrar/ocultar Ghost",
        "menu.window": "Ventana",
        "menu.minimize": "Minimizar",
        "menu.nextTab": "Pestaña siguiente",
        "menu.prevTab": "Pestaña anterior",
        "menu.tab": "Pestaña",
        "settings.title": "Ajustes",
        "settings.language": "Idioma",
        "settings.theme": "Tema",
        "settings.fontSize": "Tamaño de fuente",
        "settings.banner": "Banner de bienvenida en terminales nuevas",
        "settings.aiSummaries": "Resúmenes automáticos de Ghost (LM Studio)",
        "settings.booActions": "Permitir a boo ejecutar acciones (scripts visibles en el terminal)",
        "banner.tagline": "terminal a medida · v1.2 · ⌘T pestañas · ⌘D split · ⌘E fantasma · boo <pregunta>",
        "banner.license": "licencia: uso personal, sin garantías. si algo peta, Ghost dirá buu.",
        "ctx.askBoo": "Preguntar a boo por la selección",
        "ctx.clear": "Limpiar pantalla",
        "ctx.finder": "Abrir carpeta en Finder",
        "restored": "── sesión restaurada ──",
        "copied": "copiado ✓",
        "thinking": "a ver, dame un segundo...",
    ]

    private static let en: [String: String] = [
        "menu.about": "About Ghost",
        "menu.settings": "Settings…",
        "menu.hide": "Hide Ghost",
        "menu.quit": "Quit Ghost",
        "menu.shell": "Shell",
        "menu.newTab": "New Tab",
        "menu.split": "Split Terminal (left)",
        "menu.newWindow": "New Window",
        "menu.close": "Close",
        "menu.edit": "Edit",
        "menu.copy": "Copy",
        "menu.paste": "Paste",
        "menu.selectAll": "Select All",
        "menu.view": "View",
        "menu.fontBigger": "Increase Font Size",
        "menu.fontSmaller": "Decrease Font Size",
        "menu.theme": "Theme",
        "menu.toggleGhost": "Show/Hide Ghost",
        "menu.window": "Window",
        "menu.minimize": "Minimize",
        "menu.nextTab": "Next Tab",
        "menu.prevTab": "Previous Tab",
        "menu.tab": "Tab",
        "settings.title": "Settings",
        "settings.language": "Language",
        "settings.theme": "Theme",
        "settings.fontSize": "Font size",
        "settings.banner": "Welcome banner on new terminals",
        "settings.aiSummaries": "Automatic Ghost summaries (LM Studio)",
        "settings.booActions": "Let boo run actions (scripts visible in the terminal)",
        "banner.tagline": "custom terminal · v1.2 · ⌘T tabs · ⌘D split · ⌘E ghost · boo <question>",
        "banner.license": "license: personal use, no warranty. if something breaks, Ghost will just say boo.",
        "ctx.askBoo": "Ask boo about the selection",
        "ctx.clear": "Clear screen",
        "ctx.finder": "Reveal folder in Finder",
        "restored": "── session restored ──",
        "copied": "copied ✓",
        "thinking": "let me think for a sec...",
    ]
}

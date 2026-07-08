import Foundation

// Archivo de terminales: sesiones congeladas que no estorban en el día a día
// pero no se quieren perder (un prompt, un experimento). Se guarda el mismo
// snapshot que usa la restauración al arrancar; el scrollback sigue viviendo
// en el .log de la sesión (saveState lo respeta mientras el id esté aquí).
// Es global a toda la app y persiste en archive.json junto a restore.json.
enum SessionArchive {
    private static var url: URL {
        // costura de pruebas: FileManager ignora $HOME, así que los tests
        // apuntan aquí a un directorio propio con esta variable
        if let test = ProcessInfo.processInfo.environment["CICLOPE_TEST_SUPPORT"] {
            return URL(fileURLWithPath: test).appendingPathComponent("archive.json")
        }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ciclope", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("archive.json")
    }

    static var entries: [[String: Any]] {
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return list
    }

    static var count: Int { entries.count }

    /// IDs de las sesiones archivadas (para que saveState no barra sus logs).
    static var ids: [String] { entries.compactMap { $0["id"] as? String } }

    static func add(_ snapshot: [String: Any]) {
        var entry = snapshot
        entry["archivedAt"] = Date().timeIntervalSince1970
        save(entries + [entry])
    }

    /// Saca del archivo la entrada con ese id y la devuelve (nil si ya no está;
    /// con varias ventanas otra pudo llevársela antes).
    @discardableResult
    static func remove(id: String) -> [String: Any]? {
        var list = entries
        guard let i = list.firstIndex(where: { $0["id"] as? String == id }) else { return nil }
        let entry = list.remove(at: i)
        save(list)
        return entry
    }

    private static func save(_ list: [[String: Any]]) {
        guard let data = try? JSONSerialization.data(withJSONObject: list) else { return }
        try? data.write(to: url)
    }
}

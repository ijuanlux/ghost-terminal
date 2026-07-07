import Foundation

// Cliente mínimo para la API OpenAI-compatible de LM Studio (localhost:1234).
// Si no está corriendo, Cíclope sigue funcionando solo con reglas.
final class LMStudio {
    static let shared = LMStudio()
    private let base = URL(string: "http://127.0.0.1:1234/v1")!
    private var cachedModel: String?

    /// Nombre del modelo cargado (para firmar las respuestas del LLM).
    var modelName: String? { cachedModel }
    /// Tokens reales (prompt+completion) de la última respuesta, del campo usage.
    private(set) var lastTokens = 0
    private var lastCheck = Date.distantPast
    private var lastAvailable = false

    /// Comprueba disponibilidad. Cachea 60s si está vivo, solo 5s si no,
    /// para enterarse rápido cuando Juan enciende LM Studio.
    func checkAvailable(_ completion: @escaping (Bool) -> Void) {
        let ttl: TimeInterval = lastAvailable ? 60 : 5
        if Date().timeIntervalSince(lastCheck) < ttl {
            completion(lastAvailable)
            return
        }
        var req = URLRequest(url: base.appendingPathComponent("models"), timeoutInterval: 1.5)
        req.httpMethod = "GET"
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            var ok = false
            if let data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let models = json["data"] as? [[String: Any]],
               let first = models.first?["id"] as? String {
                self?.cachedModel = first
                ok = true
            }
            DispatchQueue.main.async {
                self?.lastCheck = Date()
                self?.lastAvailable = ok
                completion(ok)
            }
        }.resume()
    }

    /// Chat corto. `history` son intercambios previos (pregunta, respuesta) para
    /// que el modelo mantenga el hilo. Devuelve nil si LM Studio no está o falla.
    func chat(system: String, history: [(q: String, a: String)] = [], user: String, maxTokens: Int = 90,
              completion: @escaping (String?) -> Void) {
        checkAvailable { [weak self] ok in
            guard ok, let self, let model = self.cachedModel else {
                completion(nil)
                return
            }
            var req = URLRequest(url: self.base.appendingPathComponent("chat/completions"),
                                 timeoutInterval: 90)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            var messages: [[String: String]] = [["role": "system", "content": system]]
            for turn in history {
                messages.append(["role": "user", "content": turn.q])
                messages.append(["role": "assistant", "content": turn.a])
            }
            messages.append(["role": "user", "content": user])
            let body: [String: Any] = [
                "model": model,
                "messages": messages,
                "temperature": 0.8,
                "max_tokens": maxTokens,
            ]
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
                var text: String?
                var tokens = 0
                if let data,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    // tokens REALES que procesó el modelo (no una estimación)
                    if let usage = json["usage"] as? [String: Any],
                       let total = usage["total_tokens"] as? Int {
                        tokens = total
                    }
                    if let choices = json["choices"] as? [[String: Any]],
                       let msg = choices.first?["message"] as? [String: Any],
                       var content = msg["content"] as? String {
                        // limpiar razonamiento de modelos thinking y comillas
                        if let r = content.range(of: "</think>") {
                            content = String(content[r.upperBound...])
                        }
                        content = content.trimmingCharacters(in: .whitespacesAndNewlines)
                        content = content.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”"))
                        if !content.isEmpty { text = content }
                    }
                }
                DispatchQueue.main.async {
                    self?.lastTokens = tokens
                    completion(text)
                }
            }.resume()
        }
    }
}

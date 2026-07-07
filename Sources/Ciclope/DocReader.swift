import AppKit
import PDFKit

// Extrae texto plano de documentos de forma nativa (rápido y sin binarios):
// PDFKit para PDF, NSAttributedString para rtf/doc/docx/html, lectura directa
// para texto. Así boo no tiene que hacer `cat` sobre un PDF (que da basura).
enum DocReader {
    static func text(_ path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "pdf":
            guard let doc = PDFDocument(url: url) else { return nil }
            var out = ""
            for i in 0..<doc.pageCount {
                if let page = doc.page(at: i), let s = page.string {
                    out += s + "\n"
                }
                if out.count > 40_000 { break }
            }
            return out.isEmpty ? nil : out
        case "txt", "md", "markdown", "csv", "json", "xml", "yaml", "yml", "log":
            return try? String(contentsOf: url, encoding: .utf8)
        case "rtf", "doc", "docx", "html", "htm", "odt", "pages", "webarchive":
            if let attr = try? NSAttributedString(
                url: url,
                options: [.documentType: NSAttributedString.DocumentType.plain],
                documentAttributes: nil) {
                return attr.string
            }
            // fallback: dejar que AppKit deduzca el tipo
            if let attr = try? NSAttributedString(url: url, options: [:], documentAttributes: nil) {
                return attr.string
            }
            return nil
        default:
            return nil
        }
    }
}

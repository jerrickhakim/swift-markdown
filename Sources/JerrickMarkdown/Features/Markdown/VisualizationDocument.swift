import Foundation

enum VisualizationDocument {
  static func isInternalURL(_ url: URL?) -> Bool {
    // Foundation gives opaque about: URLs no path component.
    url?.absoluteString == "about:blank" || url?.absoluteString == "about:srcdoc"
  }

  static func wrap(_ fragment: String, wide: Bool = false) throws -> String {
    let sources = "https://cdnjs.cloudflare.com https://esm.sh https://cdn.jsdelivr.net https://unpkg.com https://fonts.googleapis.com https://fonts.gstatic.com https://fonts.bunny.net"
    let policy = "default-src 'none'; script-src 'unsafe-inline' \(sources); style-src 'unsafe-inline' \(sources); img-src data: blob: \(sources); font-src data: \(sources); connect-src 'none'; frame-src 'self'; object-src 'none'; base-uri 'none'; form-action 'none'"
    let child = try template("visualization-content")
      .replacingOccurrences(of: "{{policy}}", with: policy)
      .replacingOccurrences(of: "{{fragment}}", with: fragment)
    let escaped = child.replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "\"", with: "&quot;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
    return try template("visualization-frame")
      .replacingOccurrences(of: "{{policy}}", with: policy)
      .replacingOccurrences(of: "{{width}}", with: wide ? "max(100%, 1024px)" : "100%")
      .replacingOccurrences(of: "{{content}}", with: escaped)
  }

  private static func template(_ name: String) throws -> String {
    guard let url = Bundle.module.url(forResource: name, withExtension: "html") else {
      throw CocoaError(.fileNoSuchFile)
    }
    return try String(contentsOf: url, encoding: .utf8)
  }
}

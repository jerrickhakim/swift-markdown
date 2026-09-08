import Foundation

public struct MarkdownVisualizationReference: Decodable, Equatable, Sendable {
  public let path: String
  public let title: String?
  public let mode: String?
}

extension MarkdownParser {
  private static let visualizationOpening = "visualize"

  static func isVisualizationCandidate(_ line: String) -> Bool {
    let text = line.trimmingCharacters(in: .whitespaces)
    return !text.isEmpty && (visualizationOpening.hasPrefix(text)
      || text.hasPrefix(visualizationOpening))
  }

  static func parseVisualization(_ line: String) -> MarkdownBlockContent? {
    guard isVisualizationCandidate(line) else { return nil }
    let text = line.trimmingCharacters(in: .whitespaces)
    guard text.utf8.count <= 16_384 else { return nil }
    guard text.hasSuffix("") else {
      guard !text.contains("") else { return nil }
      return .visualization(reference: nil, source: line)
    }
    guard text.hasPrefix(visualizationOpening) else { return nil }
    let json = text.dropFirst(visualizationOpening.count).dropLast()
    guard let reference = try? JSONDecoder().decode(
      MarkdownVisualizationReference.self, from: Data(json.utf8)),
      !reference.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      reference.mode == nil || reference.mode == "wide"
    else { return nil }
    return .visualization(reference: reference, source: line)
  }
}

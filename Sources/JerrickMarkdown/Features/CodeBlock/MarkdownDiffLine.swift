import Foundation

/// A renderer-owned unified-diff row. Apps map their domain diff model to this
/// value at the UI boundary, keeping repository and patch parsing out of the package.
public struct MarkdownDiffLine: Identifiable, Equatable, Sendable {
  public enum Kind: Equatable, Sendable {
    case context
    case addition
    case deletion
    case hunk
  }

  public let kind: Kind
  public let content: String
  public let oldLineNumber: Int?
  public let newLineNumber: Int?

  public init(
    kind: Kind,
    content: String,
    oldLineNumber: Int? = nil,
    newLineNumber: Int? = nil
  ) {
    self.kind = kind
    self.content = content
    self.oldLineNumber = oldLineNumber
    self.newLineNumber = newLineNumber
  }

  public var id: String {
    switch kind {
    case .hunk:
      return "hunk:\(content)"
    default:
      return "\(kind)|\(oldLineNumber ?? -1)|\(newLineNumber ?? -1)"
    }
  }
}

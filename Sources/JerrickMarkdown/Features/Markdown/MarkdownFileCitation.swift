import Foundation

enum MarkdownFileCitation {
  static let openingUTF8 = Array(":codex-file-citation{".utf8)
  private static let opening = Array(String(decoding: openingUTF8, as: UTF8.self))

  static func scan(_ chars: [Character], at start: Int) -> (end: Int, path: String?)? {
    guard chars.count - start >= opening.count,
          chars[start..<(start + opening.count)].elementsEqual(opening) else { return nil }
    let limit = min(chars.count, start + 16_384)
    var end = start + opening.count
    var quoted = false
    var escaped = false
    while end < limit {
      let char = chars[end]
      if escaped { escaped = false }
      else if quoted && char == "\\" { escaped = true }
      else if char == "\"" { quoted.toggle() }
      else if char == "}" && !quoted { break }
      end += 1
    }
    guard end < limit else { return nil }
    let bodyStart = start + opening.count
    return (end + 1, parseAttributes(chars, from: bodyStart, to: end))
  }

  private static func parseAttributes(_ chars: [Character], from start: Int, to end: Int) -> String? {
    var cursor = start
    var attributes: [String: String] = [:]
    while cursor < end {
      while cursor < end && chars[cursor].isWhitespace { cursor += 1 }
      if cursor == end { break }
      let keyStart = cursor
      while cursor < end && (chars[cursor].isLetter || chars[cursor] == "_") { cursor += 1 }
      guard cursor > keyStart else { return nil }
      let key = String(chars[keyStart..<cursor])
      while cursor < end && chars[cursor].isWhitespace { cursor += 1 }
      guard cursor < end && chars[cursor] == "=" else { return nil }
      cursor += 1
      while cursor < end && chars[cursor].isWhitespace { cursor += 1 }
      guard cursor < end && chars[cursor] == "\"" else { return nil }
      let valueStart = cursor
      cursor += 1
      while cursor < end && chars[cursor] != "\"" {
        if chars[cursor] == "\\" { cursor += 1 }
        cursor += 1
      }
      guard cursor < end else { return nil }
      cursor += 1
      guard attributes[key] == nil,
            let value = try? JSONDecoder().decode(String.self,
              from: Data(String(chars[valueStart..<cursor]).utf8)) else { return nil }
      attributes[key] = value
      guard cursor == end || chars[cursor].isWhitespace else { return nil }
    }
    guard let path = attributes["path"], !path.isEmpty,
          !path.contains("\0"), !path.contains("://"),
          !path.hasSuffix("/"), !path.hasPrefix("~") else { return nil }
    return path
  }

  static func destination(for path: String) -> String? {
    if path.hasPrefix("/") { return URL(fileURLWithPath: path).absoluteString }
    var components = URLComponents()
    components.path = path
    return components.url?.absoluteString
  }
}

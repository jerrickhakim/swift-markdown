import Foundation

// MARK: - Block-level HTML parsing

/// Block-level HTML support for the custom parser. Recognized container tags
/// are mapped onto existing `MarkdownBlockContent` cases wherever possible so
/// they inherit the streaming reveal of their markdown counterparts:
///
/// - `<table>`        → `.table`       (reuses `MarkdownTable`'s cell stagger)
/// - `<pre>`/`<code>` → `.codeBlock`   (reuses `CodeBlock`)
/// - `<blockquote>`   → `.blockQuote`
/// - `<p>`/`<p align>`→ `.paragraph`   (word fade, optional alignment)
/// - `<h1>`–`<h6>`    → `.heading`
/// - `<details>`      → `.details`     (new collapsible)
/// - `<img>`/`<picture>` → skipped (no network image loading by design)
///
/// Inline-only tags (`<kbd>`, `<sup>`, …) are NOT block tags — a line opening
/// with one falls through to the paragraph path and is handled by
/// `InlineMarkdown`. Tail-tolerant: an unterminated block consumes to the end
/// of the input and re-parses as more text streams in (same discipline as
/// `parseFencedCodeBlock`).
extension MarkdownParser {

  struct HTMLBlockResult {
    /// nil when the tag is consumed but produces nothing (e.g. an image).
    let block: MarkdownBlockContent?
    let nextIndex: Int
  }

  /// Dispatch on the block tag a line opens with. Returns nil when the line
  /// isn't a recognized block-level HTML tag (the caller then tries the
  /// markdown parsers).
  static func parseHTMLBlock(lines: [String], startIndex: Int) -> HTMLBlockResult? {
    let trimmed = lines[startIndex].trimmingCharacters(in: .whitespaces)
    guard let tag = blockTagName(trimmed) else { return nil }

    switch tag {
    case "details":
      return parseDetailsBlock(lines: lines, startIndex: startIndex)
    case "table":
      return parseHTMLTableBlock(lines: lines, startIndex: startIndex)
    case "pre":
      return parsePreBlock(lines: lines, startIndex: startIndex)
    case "blockquote":
      return parseHTMLBlockquote(lines: lines, startIndex: startIndex)
    case "p":
      return parseHTMLParagraph(lines: lines, startIndex: startIndex)
    case "h1", "h2", "h3", "h4", "h5", "h6":
      let level = Int(tag.dropFirst()) ?? 3
      return parseHTMLHeading(lines: lines, startIndex: startIndex, level: level)
    case "img", "source", "picture":
      return parseSkippedHTML(lines: lines, startIndex: startIndex, tag: tag)
    default:
      return nil
    }
  }

  // MARK: Details

  private static func parseDetailsBlock(lines: [String], startIndex: Int) -> HTMLBlockResult? {
    guard let collected = collectTag("details", lines: lines, startIndex: startIndex) else {
      return nil
    }
    let open = collected.attrs.lowercased().split { !$0.isLetter }.contains("open")
    let (summaryRaw, body) = extractSummary(collected.inner)
    let summaryBlocks = summaryRaw.map { MarkdownParser.parse($0) } ?? []
    let bodyBlocks = MarkdownParser.parse(body)
    return HTMLBlockResult(
      block: .details(summary: summaryBlocks, open: open, blocks: bodyBlocks),
      nextIndex: collected.nextIndex)
  }

  static func detailsBodyForAppending(lines: [String]) -> String? {
    let chars = Array(lines.joined(separator: "\n"))
    guard let outer = scanTag(chars, at: 0, name: "details"), !outer.terminated else {
      return nil
    }
    let inner = String(chars[outer.contentStart..<outer.contentEnd])
    let innerChars = Array(inner)
    if let summaryStart = firstTagOpen(innerChars, name: "summary") {
      guard let summary = scanTag(innerChars, at: summaryStart, name: "summary"),
            summary.terminated else { return nil }
    }
    let (_, body) = extractSummary(inner)
    guard !containsByte(body.utf8, 0x3C),
          let first = body.firstIndex(where: { !$0.isWhitespace }) else { return nil }
    return String(body[first...])
  }

  /// Splits a `<details>` body into its `<summary>` (if any) and the remaining
  /// body content. The summary is returned raw so the caller can parse it as
  /// blocks (a `<summary>` may wrap a fenced code block).
  private static func extractSummary(_ inner: String) -> (summary: String?, body: String) {
    let chars = Array(inner)
    let n = chars.count
    var i = 0
    while i < n {
      if chars[i] == "<", matchTagOpen(chars, at: i, name: "summary"),
        let scan = scanTag(chars, at: i, name: "summary")
      {
        let summary = String(chars[scan.contentStart..<scan.contentEnd])
        let before = String(chars[0..<i])
        let after = scan.terminated ? String(chars[scan.closeEnd..<n]) : ""
        return (summary, before + after)
      }
      i += 1
    }
    return (nil, inner)
  }

  // MARK: Table

  private static func parseHTMLTableBlock(lines: [String], startIndex: Int) -> HTMLBlockResult? {
    guard let collected = collectTag("table", lines: lines, startIndex: startIndex) else {
      return nil
    }
    let (header, rows) = parseHTMLTableCells(collected.inner)
    guard !header.isEmpty || !rows.isEmpty else {
      return HTMLBlockResult(block: nil, nextIndex: collected.nextIndex)
    }
    return HTMLBlockResult(
      block: .table(header: header, rows: rows), nextIndex: collected.nextIndex)
  }

  private static func parseHTMLTableCells(_ inner: String) -> (header: [String], rows: [[String]]) {
    let chars = Array(inner)
    let n = chars.count
    var header: [String] = []
    var rows: [[String]] = []
    var i = 0
    while i < n {
      if chars[i] == "<", matchTagOpen(chars, at: i, name: "tr"),
        let row = scanTag(chars, at: i, name: "tr")
      {
        let (cells, isHeaderRow) = parseRowCells(
          String(chars[row.contentStart..<row.contentEnd]))
        if isHeaderRow, header.isEmpty {
          header = cells
        } else {
          rows.append(cells)
        }
        i = row.terminated ? row.closeEnd : n
      } else {
        i += 1
      }
    }
    // No explicit <th> header row — promote the first body row.
    if header.isEmpty, !rows.isEmpty {
      header = rows.removeFirst()
    }
    return (header, rows)
  }

  private static func parseRowCells(_ rowInner: String) -> (cells: [String], isHeader: Bool) {
    let chars = Array(rowInner)
    let n = chars.count
    var cells: [String] = []
    var isHeader = false
    var i = 0
    while i < n {
      guard chars[i] == "<" else {
        i += 1
        continue
      }
      if matchTagOpen(chars, at: i, name: "th"), let cell = scanTag(chars, at: i, name: "th") {
        cells.append(cellText(chars, cell))
        isHeader = true
        i = cell.terminated ? cell.closeEnd : n
      } else if matchTagOpen(chars, at: i, name: "td"),
        let cell = scanTag(chars, at: i, name: "td")
      {
        cells.append(cellText(chars, cell))
        i = cell.terminated ? cell.closeEnd : n
      } else {
        i += 1
      }
    }
    return (cells, isHeader)
  }

  /// Cell text keeps inline HTML (`<code>`, `<strong>`, …) and entities intact —
  /// `MarkdownTable` renders each cell through `InlineMarkdown`, which decodes
  /// them. Only the source line wrapping is collapsed to a single space.
  private static func cellText(_ chars: [Character], _ scan: TagScan) -> String {
    String(chars[scan.contentStart..<scan.contentEnd])
      .replacingOccurrences(of: "\n", with: " ")
      .trimmingCharacters(in: .whitespaces)
  }

  // MARK: Pre / code

  private static func parsePreBlock(lines: [String], startIndex: Int) -> HTMLBlockResult? {
    guard let collected = collectTag("pre", lines: lines, startIndex: startIndex) else {
      return nil
    }
    var raw = collected.inner
    var language: String?

    // <pre><code class="language-go">…</code></pre>
    let chars = Array(raw)
    if let codeOpen = firstTagOpen(chars, name: "code"),
      let code = scanTag(chars, at: codeOpen, name: "code")
    {
      language = languageFromClass(code.attrs)
      raw = String(chars[code.contentStart..<code.contentEnd])
    }

    let code = trimPreContent(InlineMarkdown.decodeEntities(raw))
    return HTMLBlockResult(
      block: .codeBlock(language: language, code: code), nextIndex: collected.nextIndex)
  }

  /// Drops a single leading newline (`<pre>\n…`) and trailing whitespace lines,
  /// preserving interior indentation.
  private static func trimPreContent(_ s: String) -> String {
    var out = s
    if out.hasPrefix("\n") { out.removeFirst() }
    while out.hasSuffix("\n") || out.hasSuffix(" ") { out.removeLast() }
    return out
  }

  // MARK: Blockquote

  private static func parseHTMLBlockquote(lines: [String], startIndex: Int) -> HTMLBlockResult? {
    guard let collected = collectTag("blockquote", lines: lines, startIndex: startIndex) else {
      return nil
    }
    // Strip the <p> wrappers (→ paragraph breaks) and skipped media; inline
    // tags stay for the inline parser that renders the quote. Newlines are
    // preserved so multi-paragraph quotes keep their breaks.
    var text = stripSkippedTags(collected.inner)
    text = text.replacingOccurrences(
      of: "</p>", with: "\n\n", options: .caseInsensitive)
    text = text.replacingOccurrences(
      of: "<p[^>]*>", with: "", options: [.regularExpression, .caseInsensitive])
    text = text.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
      .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else {
      return HTMLBlockResult(block: nil, nextIndex: collected.nextIndex)
    }
    return HTMLBlockResult(block: .blockQuote(text: text), nextIndex: collected.nextIndex)
  }

  // MARK: Paragraph / heading

  private static func parseHTMLParagraph(lines: [String], startIndex: Int) -> HTMLBlockResult? {
    guard let collected = collectTag("p", lines: lines, startIndex: startIndex) else {
      return nil
    }
    let alignment = alignmentFromAttrs(collected.attrs)
    let text = inlineText(from: collected.inner)
    guard !text.isEmpty else {
      // e.g. a <p align="center"> wrapping only images — nothing left to show.
      return HTMLBlockResult(block: nil, nextIndex: collected.nextIndex)
    }
    return HTMLBlockResult(
      block: .paragraph(text: text, alignment: alignment), nextIndex: collected.nextIndex)
  }

  private static func parseHTMLHeading(lines: [String], startIndex: Int, level: Int)
    -> HTMLBlockResult?
  {
    let tag = "h\(level)"
    guard let collected = collectTag(tag, lines: lines, startIndex: startIndex) else {
      return nil
    }
    let alignment = alignmentFromAttrs(collected.attrs)
    let text = inlineText(from: collected.inner)
    guard !text.isEmpty else {
      return HTMLBlockResult(block: nil, nextIndex: collected.nextIndex)
    }
    return HTMLBlockResult(
      block: .heading(level: level, text: text, alignment: alignment),
      nextIndex: collected.nextIndex)
  }

  /// Inner text for an inline container (`<p>`, `<h*>`): strip skipped media
  /// tags, collapse source line wrapping to spaces (HTML whitespace folding),
  /// and keep inline tags/entities for `InlineMarkdown`. `<br>` survives and
  /// becomes a line break in the inline parser.
  private static func inlineText(from inner: String) -> String {
    stripSkippedTags(inner)
      .replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: " +", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespaces)
  }

  // MARK: Skipped media

  private static func parseSkippedHTML(lines: [String], startIndex: Int, tag: String)
    -> HTMLBlockResult?
  {
    if tag == "picture" {
      // Balanced container — consume the whole thing.
      guard let collected = collectTag("picture", lines: lines, startIndex: startIndex) else {
        return nil
      }
      return HTMLBlockResult(block: nil, nextIndex: collected.nextIndex)
    }
    // Void element (<img>, <source>) — consume through its closing ">".
    let chars = Array(lines[startIndex...].joined(separator: "\n"))
    var k = 0
    while k < chars.count, chars[k] != ">" { k += 1 }
    guard k < chars.count else {
      return HTMLBlockResult(block: nil, nextIndex: lines.count)
    }
    let newlines = chars[0...k].reduce(0) { $0 + ($1 == "\n" ? 1 : 0) }
    return HTMLBlockResult(
      block: nil, nextIndex: min(startIndex + newlines + 1, lines.count))
  }

  // MARK: - Tag scanning core

  struct TagScan {
    /// Text inside the opening tag after the `<` — i.e. `"name attr=…"`.
    let attrs: String
    let contentStart: Int
    /// Index of the matching close tag's `<`, or the end of input if unterminated.
    let contentEnd: Int
    /// Index just past the close tag's `>`, or end of input if unterminated.
    let closeEnd: Int
    /// True only when the matching close tag was found.
    let terminated: Bool
  }

  /// Scans a balanced `<name>…</name>` starting at/after `start` (leading
  /// whitespace skipped), depth-aware for nested same-name tags. Returns nil
  /// when `name` doesn't open here.
  static func scanTag(_ chars: [Character], at start: Int, name: String) -> TagScan? {
    let n = chars.count
    var i = start
    while i < n, chars[i].isWhitespace { i += 1 }
    guard matchTagOpen(chars, at: i, name: name) else { return nil }

    var k = i
    while k < n, chars[k] != ">" { k += 1 }
    guard k < n else {
      // Opening tag not yet closed (streaming) — nothing to render yet.
      return TagScan(
        attrs: String(chars[(i + 1)..<n]), contentStart: n, contentEnd: n, closeEnd: n,
        terminated: false)
    }
    let attrs = String(chars[(i + 1)..<k])
    let contentStart = k + 1

    var depth = 1
    var j = contentStart
    while j < n {
      if chars[j] == "<" {
        if matchTagClose(chars, at: j, name: name) {
          depth -= 1
          if depth == 0 {
            var m = j
            while m < n, chars[m] != ">" { m += 1 }
            let closeEnd = m < n ? m + 1 : n
            return TagScan(
              attrs: attrs, contentStart: contentStart, contentEnd: j, closeEnd: closeEnd,
              terminated: m < n)
          }
          j += 1
        } else if matchTagOpen(chars, at: j, name: name) {
          depth += 1
          j += 1
        } else {
          j += 1
        }
      } else {
        j += 1
      }
    }
    // Unterminated — consume to end (streaming tail).
    return TagScan(
      attrs: attrs, contentStart: contentStart, contentEnd: n, closeEnd: n, terminated: false)
  }

  /// Line-based wrapper around `scanTag`: collects a tag's attributes + inner
  /// content and the source line index to resume parsing from.
  private static func collectTag(_ tag: String, lines: [String], startIndex: Int)
    -> (attrs: String, inner: String, nextIndex: Int)?
  {
    let chars = Array(lines[startIndex...].joined(separator: "\n"))
    guard let scan = scanTag(chars, at: 0, name: tag) else { return nil }
    let inner = String(chars[scan.contentStart..<scan.contentEnd])
    let nextIndex: Int
    if scan.terminated {
      let newlines = chars[0..<scan.closeEnd].reduce(0) { $0 + ($1 == "\n" ? 1 : 0) }
      nextIndex = min(startIndex + newlines + 1, lines.count)
    } else {
      nextIndex = lines.count
    }
    return (scan.attrs, inner, nextIndex)
  }

  // MARK: - Tag matching helpers

  /// True when `chars[i]` opens `<name` followed by a tag boundary (`>`, `/`,
  /// or whitespace). Case-insensitive on the name.
  static func matchTagOpen(_ chars: [Character], at i: Int, name: String) -> Bool {
    let n = chars.count
    guard i < n, chars[i] == "<" else { return false }
    var j = i + 1
    for ch in name {
      guard j < n, chars[j].lowercased() == String(ch) else { return false }
      j += 1
    }
    guard j < n else { return false }
    let after = chars[j]
    return after == ">" || after == "/" || after.isWhitespace
  }

  /// True when `chars[i]` opens `</name` followed by a boundary (`>` or space).
  static func matchTagClose(_ chars: [Character], at i: Int, name: String) -> Bool {
    let n = chars.count
    guard i + 1 < n, chars[i] == "<", chars[i + 1] == "/" else { return false }
    var j = i + 2
    for ch in name {
      guard j < n, chars[j].lowercased() == String(ch) else { return false }
      j += 1
    }
    guard j < n else { return false }
    let after = chars[j]
    return after == ">" || after.isWhitespace
  }

  private static func firstTagOpen(_ chars: [Character], name: String) -> Int? {
    var i = 0
    while i < chars.count {
      if chars[i] == "<", matchTagOpen(chars, at: i, name: name) { return i }
      i += 1
    }
    return nil
  }

  /// The block tag a trimmed line opens with (lowercased), or nil for a close
  /// tag / comment / non-tag line.
  private static func blockTagName(_ trimmed: String) -> String? {
    let chars = Array(trimmed)
    guard chars.first == "<" else { return nil }
    var j = 1
    if j < chars.count, chars[j] == "/" { return nil }  // closing tag
    let start = j
    while j < chars.count, chars[j].isLetter || chars[j].isNumber { j += 1 }
    guard j > start else { return nil }
    return String(chars[start..<j]).lowercased()
  }

  // MARK: - Attribute helpers

  private static func alignmentFromAttrs(_ attrs: String) -> MarkdownAlignment {
    let lower = attrs.lowercased()
    if lower.contains("center") { return .center }
    if lower.contains("right") || lower.contains("end") { return .trailing }
    return .leading
  }

  private static func languageFromClass(_ attrs: String) -> String? {
    guard let range = attrs.range(of: "language-") else { return nil }
    let lang = attrs[range.upperBound...].prefix {
      $0.isLetter || $0.isNumber || $0 == "+" || $0 == "#" || $0 == "-"
    }
    return lang.isEmpty ? nil : String(lang)
  }

  /// Removes media tags the renderer skips (`<img>`, `<source>`,
  /// `<picture>…</picture>`) so they don't render as literal text inside a
  /// paragraph or heading.
  private static func stripSkippedTags(_ s: String) -> String {
    var out = s
    out = out.replacingOccurrences(
      of: "<picture[\\s\\S]*?</picture>", with: "",
      options: [.regularExpression, .caseInsensitive])
    out = out.replacingOccurrences(
      of: "<img[^>]*>", with: "", options: [.regularExpression, .caseInsensitive])
    out = out.replacingOccurrences(
      of: "<source[^>]*>", with: "", options: [.regularExpression, .caseInsensitive])
    return out
  }
}

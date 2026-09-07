import Foundation
import UIKit

// MARK: - Theme colors

extension SyntaxTheme {
  /// Appearance-dynamic color for a scope (nil = default foreground).
  ///
  /// Resolved by UIKit at draw time rather than baked to one appearance: iOS
  /// re-renders the UI in both light and dark traits when it snapshots for the
  /// app switcher, so a color captured under one appearance can end up drawn
  /// under the other. Lives here rather than in the generated theme file,
  /// which codegen overwrites.
  static func uiColor(_ scope: String?) -> UIColor {
    UIColor { traits in
      let dark = traits.userInterfaceStyle == .dark
      let hex =
        scope.flatMap { color(forScope: $0, dark: dark) }
        ?? (dark ? defaultForeground.dark : defaultForeground.light)
      return UIColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: 1)
    }
  }
}

// MARK: - Rules

/// One string form a language accepts: `"…"`, `'…'`, a Swift `"""…"""`, a
/// Python `'''…'''`, a shell `$'…'`.
struct SyntaxStringRule {
  var open: String
  var close: String
  /// Escape character honoured inside the literal (`\` almost everywhere; nil
  /// for raw forms like YAML single quotes).
  var escape: Character?
  /// False means the literal ends at a newline even if unterminated — keeps a
  /// stray quote from painting the rest of the block as one string.
  var multiline: Bool = false
  /// Interpolation delimiters (`\(` … `)` in Swift, `${` … `}` in TS/JS/shell),
  /// rendered in the substitution color instead of the string color.
  var interpolation: (open: String, close: String)?

  init(
    _ open: String, _ close: String, escape: Character? = "\\", multiline: Bool = false,
    interpolation: (open: String, close: String)? = nil
  ) {
    self.open = open
    self.close = close
    self.escape = escape
    self.multiline = multiline
    self.interpolation = interpolation
  }
}

/// How a language is scanned. Most are `code`; markup and markdown have
/// structure that a keyword lexer can't express.
enum SyntaxMode {
  case code
  /// Tag/attribute structure: `<tag attr="value">`, `<!-- … -->`.
  case markup
  /// Line-led structure: headings, quotes, bullets, code spans, links.
  case markdown
  /// Unified diff: `+`/`-` rows, `@@` hunks, `---`/`+++` file headers.
  case diff
}

/// A language's lexical surface — everything the scanner needs to color it.
/// Deliberately data, not code: adding a C-family language is a keyword set.
struct SyntaxRules {
  var mode: SyntaxMode = .code
  var lineComments: [String] = []
  var blockComment: (open: String, close: String, nests: Bool)?
  var strings: [SyntaxStringRule] = []
  var keywords: Set<String> = []
  var literals: Set<String> = []
  var types: Set<String> = []
  var builtins: Set<String> = []
  /// Characters that may appear inside an identifier beyond letters, digits
  /// and `_` — `$` in JS, `@`/`?`/`!` in Ruby, `-` in CSS and Lisp-ish names.
  var identifierExtras: Set<Character> = []
  /// After one of these, the next identifier is the thing being declared and
  /// takes the function color: `func greet`, `def greet`, `fn greet`.
  var functionDeclKeywords: Set<String> = []
  /// Same, but for the type color: `class User`, `struct User`, `interface User`.
  var typeDeclKeywords: Set<String> = []
  /// An unknown identifier starting with a capital reads as a type. True for
  /// languages that actually follow the convention; false for e.g. Python and
  /// bash, where it would paint constants as types.
  var capitalizedIdentifiersAreTypes = false
  /// SQL keywords are conventionally uppercase but legal in any case.
  var caseInsensitiveKeywords = false
  /// A quoted string immediately followed by `:` is a key (JSON, YAML, JS
  /// object literals).
  var quotedKeysBeforeColon = false
  /// An unquoted identifier at the head of a line followed by `:` is a key
  /// (YAML, and close enough for TOML tables).
  var bareKeysBeforeColon = false
  /// Lines whose first non-space character is this get the meta color —
  /// `#include`, `#!/usr/bin/env`, `@Directive`.
  var metaLinePrefixes: [String] = []
}

// MARK: - Scanner

/// A hand-rolled syntax highlighter: one left-to-right pass over the code,
/// emitting colored runs straight into an `NSAttributedString`.
///
/// Replaced highlight.js (JavaScriptCore) because that path was asynchronous —
/// it ran on an actor behind a `JSContext` and reached the view through a
/// `@State` model, so any hiccup in the chain left a block rendered plain with
/// nothing to repaint it. This is synchronous and cheap enough to call from
/// `body` on every render, so a block cannot be left un-highlighted by a
/// lifecycle event.
///
/// It is a lexer, not a parser: no nesting of one language inside another (no
/// JS inside `<script>`, no SQL inside a string), which for chat code blocks is
/// invisible.
enum NativeSyntaxHighlighter {

  /// Colored lines for `code`, one per newline-separated line. Nil when the
  /// language is explicitly plain text, or when the output somehow doesn't
  /// round-trip the input — in both cases the caller renders plain.
  static func lines(code: String, language: String) -> [AttributedString]? {
    guard let rules = SyntaxLanguages.rules(for: language) else { return nil }
    return splitLines(
      AttributedString(attributed(code: code, rules: rules)), matching: code)
  }

  /// Splits the highlighted text on newlines and verifies the line count
  /// matches the plain code's — the scanner round-trips the text verbatim, but
  /// if it ever doesn't, plain rendering wins over misaligned colors.
  static func splitLines(
    _ attributed: AttributedString, matching code: String
  ) -> [AttributedString]? {
    var lines: [AttributedString] = []
    let characters = attributed.characters
    var lineStart = attributed.startIndex
    var index = characters.startIndex
    while index < characters.endIndex {
      if characters[index].isNewline {
        lines.append(AttributedString(attributed[lineStart..<index]))
        lineStart = characters.index(after: index)
      }
      index = characters.index(after: index)
    }
    lines.append(AttributedString(attributed[lineStart..<attributed.endIndex]))

    let expected = code.components(separatedBy: .newlines).count
    guard lines.count == expected else { return nil }
    return lines
  }

  // MARK: Pass

  private static func attributed(code: String, rules: SyntaxRules)
    -> NSAttributedString
  {
    switch rules.mode {
    case .markup: return markup(code)
    case .markdown: return markdownText(code)
    case .diff: return diffText(code)
    case .code: break
    }
    let chars = Array(code)
    let out = NSMutableAttributedString()
    var plain = ""  // pending default-colored text
    var index = 0
    /// The last keyword seen on this logical statement, so `func` can promote
    /// the identifier that follows it.
    var pendingDecl: String?
    /// First non-space column of the current line — drives `bareKeysBeforeColon`
    /// and the meta-line prefixes.
    var atLineStart = true

    func flushPlain() {
      guard !plain.isEmpty else { return }
      out.append(run(plain, scope: nil))
      plain = ""
    }

    func emit(_ text: String, _ scope: String) {
      flushPlain()
      out.append(run(text, scope: scope))
    }

    while index < chars.count {
      let ch = chars[index]

      if ch == "\n" {
        plain.append(ch)
        index += 1
        atLineStart = true
        pendingDecl = nil
        continue
      }
      if ch == " " || ch == "\t" {
        plain.append(ch)
        index += 1
        continue
      }

      // Meta lines (`#include`, shebangs, annotations) — whole line, one color.
      if atLineStart, rules.metaLinePrefixes.contains(where: { match($0, chars, index) }) {
        let end = lineEnd(chars, from: index)
        emit(String(chars[index..<end]), "meta")
        index = end
        atLineStart = false
        continue
      }
      atLineStart = false

      // Line comment
      if rules.lineComments.contains(where: { match($0, chars, index) }) {
        let end = lineEnd(chars, from: index)
        emit(String(chars[index..<end]), "comment")
        index = end
        continue
      }

      // Block comment
      if let block = rules.blockComment, match(block.open, chars, index) {
        let end = blockCommentEnd(chars, from: index, block: block)
        emit(String(chars[index..<end]), "comment")
        index = end
        continue
      }

      // String literal (longest opener first, so `"""` beats `"`)
      if let rule = rules.strings
        .filter({ match($0.open, chars, index) })
        .max(by: { $0.open.count < $1.open.count })
      {
        flushPlain()
        index = scanString(chars, from: index, rule: rule, into: out)
        // A quoted key keeps the string color unless the language marks keys.
        if rules.quotedKeysBeforeColon, nextNonSpace(chars, from: index) == ":" {
          recolorLast(out, scope: "attr")
        }
        continue
      }

      // Number
      if ch.isNumber || (ch == "." && index + 1 < chars.count && chars[index + 1].isNumber) {
        let end = numberEnd(chars, from: index)
        emit(String(chars[index..<end]), "number")
        index = end
        continue
      }

      // Identifier / keyword
      if isIdentifierStart(ch, rules: rules) {
        var end = index + 1
        while end < chars.count, isIdentifierBody(chars[end], rules: rules) { end += 1 }
        let word = String(chars[index..<end])
        emit(word, scope(for: word, chars: chars, end: end, rules: rules, pendingDecl: &pendingDecl))
        index = end
        continue
      }

      // Operators and punctuation get their own color; the default foreground
      // is the variable color, which would make brackets read as identifiers.
      emit(String(ch), "operator")
      index += 1
    }

    flushPlain()
    return out
  }

  // MARK: Markup

  /// HTML/XML: tag names, attribute names, quoted values, comments. Embedded
  /// `<script>`/`<style>` bodies stay plain — coloring them would mean running
  /// a second language, which this lexer deliberately doesn't do.
  private static func markup(_ code: String) -> NSAttributedString {
    let chars = Array(code)
    let out = NSMutableAttributedString()
    var plain = ""
    var index = 0

    func flushPlain() {
      guard !plain.isEmpty else { return }
      out.append(NSAttributedString(string: plain, attributes: [.foregroundColor: SyntaxTheme.uiColor(nil)]))
      plain = ""
    }
    func emit(_ text: String, _ scope: String) {
      flushPlain()
      out.append(NSAttributedString(string: text, attributes: [.foregroundColor: SyntaxTheme.uiColor(scope)]))
    }

    while index < chars.count {
      guard chars[index] == "<" else {
        plain.append(chars[index])
        index += 1
        continue
      }

      if match("<!--", chars, index) {
        var end = index
        while end < chars.count, !match("-->", chars, end) { end += 1 }
        end = min(chars.count, end + 3)
        emit(String(chars[index..<end]), "comment")
        index = end
        continue
      }

      // `<`, optional `/`, tag name
      var cursor = index + 1
      if cursor < chars.count, chars[cursor] == "/" || chars[cursor] == "!" || chars[cursor] == "?" {
        cursor += 1
      }
      var nameEnd = cursor
      while nameEnd < chars.count, chars[nameEnd].isLetter || chars[nameEnd].isNumber
        || chars[nameEnd] == "-" || chars[nameEnd] == "_" || chars[nameEnd] == ":"
      {
        nameEnd += 1
      }
      guard nameEnd > cursor else {  // a bare `<` in text
        plain.append(chars[index])
        index += 1
        continue
      }
      emit(String(chars[index..<cursor]), "operator")
      emit(String(chars[cursor..<nameEnd]), "name")
      index = nameEnd

      // Attributes until the closing `>`
      while index < chars.count, chars[index] != ">" {
        let ch = chars[index]
        if ch == "\"" || ch == "'" {
          var end = index + 1
          while end < chars.count, chars[end] != ch, chars[end] != "\n" { end += 1 }
          end = min(chars.count, end + 1)
          emit(String(chars[index..<end]), "string")
          index = end
          continue
        }
        if ch.isLetter || ch == "_" {
          var end = index
          while end < chars.count, chars[end].isLetter || chars[end].isNumber || chars[end] == "-"
            || chars[end] == "_" || chars[end] == ":"
          {
            end += 1
          }
          emit(String(chars[index..<end]), "attr")
          index = end
          continue
        }
        if ch == "=" || ch == "/" {
          emit(String(ch), "operator")
        } else {
          plain.append(ch)
        }
        index += 1
      }
      if index < chars.count {
        emit(">", "operator")
        index += 1
      }
    }
    flushPlain()
    return out
  }

  // MARK: Markdown

  /// Markdown is line-led: the structure that matters (headings, quotes,
  /// bullets, fences) is decided by how a line starts, with inline code spans
  /// and link targets colored within the line.
  private static func markdownText(_ code: String) -> NSAttributedString {
    let out = NSMutableAttributedString()
    var inFence = false

    func append(_ text: String, _ scope: String?) {
      out.append(NSAttributedString(string: text, attributes: [.foregroundColor: SyntaxTheme.uiColor(scope)]))
    }

    let lines = code.components(separatedBy: "\n")
    for (index, line) in lines.enumerated() {
      defer { if index < lines.count - 1 { append("\n", nil) } }
      let trimmed = line.trimmingCharacters(in: .whitespaces)

      if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
        inFence.toggle()
        append(line, "string")
        continue
      }
      if inFence {
        append(line, "string")
        continue
      }
      if trimmed.hasPrefix("#") {
        append(line, "section")
        continue
      }
      if trimmed.hasPrefix(">") {
        append(line, "quote")
        continue
      }
      markdownInline(line, into: out)
    }
    return out
  }

  /// Inline pass: bullet/number prefix, `code` spans, and `[text](target)`
  /// targets. Emphasis markers are left plain — the palette has no bold scope
  /// and coloring the asterisks alone reads worse than leaving them.
  private static func markdownInline(_ line: String, into out: NSMutableAttributedString) {
    let chars = Array(line)
    var index = 0
    var plain = ""

    func flushPlain() {
      guard !plain.isEmpty else { return }
      out.append(NSAttributedString(string: plain, attributes: [.foregroundColor: SyntaxTheme.uiColor(nil)]))
      plain = ""
    }
    func emit(_ text: String, _ scope: String) {
      flushPlain()
      out.append(NSAttributedString(string: text, attributes: [.foregroundColor: SyntaxTheme.uiColor(scope)]))
    }

    // Leading bullet or ordered marker
    var lead = 0
    while lead < chars.count, chars[lead] == " " { lead += 1 }
    if lead < chars.count {
      let ch = chars[lead]
      if (ch == "-" || ch == "*" || ch == "+"), lead + 1 < chars.count, chars[lead + 1] == " " {
        plain = String(chars[0..<lead])
        emit(String(ch), "bullet")
        index = lead + 1
      } else if ch.isNumber {
        var end = lead
        while end < chars.count, chars[end].isNumber { end += 1 }
        if end < chars.count, chars[end] == "." {
          plain = String(chars[0..<lead])
          emit(String(chars[lead...end]), "bullet")
          index = end + 1
        }
      }
    }

    while index < chars.count {
      let ch = chars[index]
      if ch == "`" {
        var end = index + 1
        while end < chars.count, chars[end] != "`" { end += 1 }
        end = min(chars.count, end + 1)
        emit(String(chars[index..<end]), "string")
        index = end
        continue
      }
      if ch == "(", index > 0, chars[index - 1] == "]" {
        var end = index + 1
        while end < chars.count, chars[end] != ")" { end += 1 }
        end = min(chars.count, end + 1)
        emit(String(chars[index..<end]), "link")
        index = end
        continue
      }
      plain.append(ch)
      index += 1
    }
    flushPlain()
  }

  // MARK: Diff

  /// A unified diff colors by row, not by token: what matters is whether a line
  /// was added, removed or is context. Syntax-coloring the code on top (as
  /// highlight.js does for context lines only) reads as noise, because the same
  /// line changes color depending on whether it happens to be part of the hunk.
  private static func diffText(_ code: String) -> NSAttributedString {
    let out = NSMutableAttributedString()
    let lines = code.components(separatedBy: "\n")

    for (index, line) in lines.enumerated() {
      let scope: String?
      if line.hasPrefix("+++") || line.hasPrefix("---") {
        scope = "meta"
      } else if line.hasPrefix("@@") {
        scope = "section"
      } else if line.hasPrefix("+") {
        scope = "addition"
      } else if line.hasPrefix("-") {
        scope = "deletion"
      } else if line.hasPrefix("diff ") || line.hasPrefix("index ") {
        scope = "comment"
      } else {
        scope = nil
      }
      out.append(
        NSAttributedString(string: line, attributes: [.foregroundColor: SyntaxTheme.uiColor(scope)]))
      if index < lines.count - 1 {
        out.append(
          NSAttributedString(string: "\n", attributes: [.foregroundColor: SyntaxTheme.uiColor(nil)]))
      }
    }
    return out
  }

  // MARK: Identifier classification

  private static func scope(
    for word: String, chars: [Character], end: Int, rules: SyntaxRules,
    pendingDecl: inout String?
  ) -> String {
    let probe = rules.caseInsensitiveKeywords ? word.lowercased() : word

    if let decl = pendingDecl {
      pendingDecl = nil
      if rules.typeDeclKeywords.contains(decl) { return "class_" }
      if rules.functionDeclKeywords.contains(decl) { return "title" }
    }

    if rules.keywords.contains(probe) {
      if rules.functionDeclKeywords.contains(probe) || rules.typeDeclKeywords.contains(probe) {
        pendingDecl = probe
      }
      return "keyword"
    }
    if rules.literals.contains(probe) { return "literal" }
    if rules.types.contains(word) { return "type" }
    if rules.builtins.contains(word) { return "built_in" }

    // `name(` is a call; `name:` at the head of a line is a key.
    if nextNonSpace(chars, from: end) == "(" { return "title" }
    if rules.bareKeysBeforeColon, nextNonSpace(chars, from: end) == ":",
      isFirstWordOnLine(chars, wordEnd: end, word: word)
    {
      return "attr"
    }
    if rules.capitalizedIdentifiersAreTypes, let first = word.first, first.isUppercase {
      return "type"
    }
    return "variable"
  }

  // MARK: Scanning primitives

  /// Consumes a string literal, emitting the quoted body in the string color
  /// and any interpolated spans in the substitution color. Returns the index
  /// just past the closing delimiter.
  private static func scanString(
    _ chars: [Character], from start: Int, rule: SyntaxStringRule,
    into out: NSMutableAttributedString
  ) -> Int {
    var index = start + rule.open.count
    var buffer = rule.open

    func flush() {
      guard !buffer.isEmpty else { return }
      out.append(run(buffer, scope: "string"))
      buffer = ""
    }

    while index < chars.count {
      let ch = chars[index]

      if let escape = rule.escape, ch == escape, index + 1 < chars.count {
        buffer.append(ch)
        buffer.append(chars[index + 1])
        index += 2
        continue
      }
      if !rule.multiline, ch == "\n" { break }

      if let interpolation = rule.interpolation, match(interpolation.open, chars, index) {
        flush()
        let end = balancedEnd(
          chars, from: index, open: interpolation.open, close: interpolation.close)
        out.append(run(String(chars[index..<end]), scope: "subst"))
        index = end
        continue
      }
      if match(rule.close, chars, index) {
        buffer += rule.close
        index += rule.close.count
        flush()
        return index
      }
      buffer.append(ch)
      index += 1
    }
    flush()
    return index
  }

  private static func numberEnd(_ chars: [Character], from start: Int) -> Int {
    var index = start
    // 0x / 0b / 0o prefix
    if chars[index] == "0", index + 1 < chars.count,
      "xXbBoO".contains(chars[index + 1])
    {
      index += 2
    }
    while index < chars.count {
      let ch = chars[index]
      if ch.isHexDigit || ch == "_" || ch == "." {
        index += 1
      } else if ch == "e" || ch == "E",
        index + 1 < chars.count, chars[index + 1].isNumber || chars[index + 1] == "-"
          || chars[index + 1] == "+"
      {
        index += 2
      } else {
        break
      }
    }
    // A trailing dot belongs to member access (`1.description`), not the number.
    if index > start, chars[index - 1] == "." { index -= 1 }
    return index
  }

  private static func blockCommentEnd(
    _ chars: [Character], from start: Int, block: (open: String, close: String, nests: Bool)
  ) -> Int {
    var index = start + block.open.count
    var depth = 1
    while index < chars.count {
      if block.nests, match(block.open, chars, index) {
        depth += 1
        index += block.open.count
        continue
      }
      if match(block.close, chars, index) {
        depth -= 1
        index += block.close.count
        if depth == 0 { return index }
        continue
      }
      index += 1
    }
    return chars.count
  }

  /// End of a `${…}` / `\(…)` span, counting nested delimiters so a dictionary
  /// literal inside an interpolation doesn't terminate it early.
  private static func balancedEnd(
    _ chars: [Character], from start: Int, open: String, close: String
  ) -> Int {
    var index = start + open.count
    var depth = 1
    while index < chars.count {
      if match(open, chars, index) {
        depth += 1
        index += open.count
        continue
      }
      if match(close, chars, index) {
        depth -= 1
        index += close.count
        if depth == 0 { return index }
        continue
      }
      index += 1
    }
    return chars.count
  }

  private static func lineEnd(_ chars: [Character], from start: Int) -> Int {
    var index = start
    while index < chars.count, chars[index] != "\n" { index += 1 }
    return index
  }

  // MARK: Helpers

  private static func match(_ token: String, _ chars: [Character], _ index: Int) -> Bool {
    let token = Array(token)
    guard index + token.count <= chars.count else { return false }
    for (offset, ch) in token.enumerated() where chars[index + offset] != ch { return false }
    return true
  }

  private static func isIdentifierStart(_ ch: Character, rules: SyntaxRules) -> Bool {
    ch.isLetter || ch == "_" || rules.identifierExtras.contains(ch)
  }

  private static func isIdentifierBody(_ ch: Character, rules: SyntaxRules) -> Bool {
    ch.isLetter || ch.isNumber || ch == "_" || rules.identifierExtras.contains(ch)
  }

  private static func nextNonSpace(_ chars: [Character], from index: Int) -> Character? {
    var cursor = index
    while cursor < chars.count, chars[cursor] == " " || chars[cursor] == "\t" { cursor += 1 }
    return cursor < chars.count ? chars[cursor] : nil
  }

  private static func isFirstWordOnLine(_ chars: [Character], wordEnd: Int, word: String) -> Bool {
    var cursor = wordEnd - word.count - 1
    while cursor >= 0 {
      let ch = chars[cursor]
      if ch == "\n" { return true }
      if ch != " " && ch != "\t" && ch != "-" { return false }
      cursor -= 1
    }
    return true
  }

  /// Repaints the run just appended — used when a trailing `:` reveals that the
  /// string we already emitted was a key, not a value.
  private static func recolorLast(_ out: NSMutableAttributedString, scope: String) {
    guard out.length > 0 else { return }
    var effective = NSRange(location: 0, length: 0)
    _ = out.attribute(.foregroundColor, at: out.length - 1, effectiveRange: &effective)
    guard effective.length > 0 else { return }
    out.addAttribute(.foregroundColor, value: SyntaxTheme.uiColor(scope), range: effective)
  }

  private static func run(_ text: String, scope: String?) -> NSAttributedString {
    NSAttributedString(string: text, attributes: [.foregroundColor: SyntaxTheme.uiColor(scope)])
  }
}

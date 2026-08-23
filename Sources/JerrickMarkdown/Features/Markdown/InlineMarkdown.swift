import Foundation
import SwiftUI

/// Streaming-tolerant inline markdown parser.
///
/// Parses one block's inline content (`**bold**`, `*em*`, `` `code` ``,
/// `[link](url)`, `~~strike~~`, escapes) into styled trait runs and an
/// `AttributedString`. The key difference from cmark/Foundation parsers is
/// `isTail`: when the input is the still-growing tail of a stream, incomplete
/// syntax is a *parse state*, not an error:
///
/// - unclosed `**` / `*` / `~~` with content after it → styled through to the end,
///   markers hidden
/// - a dangling marker run at the very end (`"word **"`) → hidden until the next
///   chunk decides what it is
/// - unclosed `` ` `` → code-styled through to the end
/// - `[text` or `[text](partial-url` → link-colored but inert (no tap target)
/// - incomplete `![image` → hidden entirely
///
/// This replaces the remend string-repair pass for the live path: nothing is
/// appended to the source text, so there is no second parse and no flash of
/// literal markers.
///
/// Known, deliberate simplifications vs cmark (kept out of the differential
/// test corpus): emphasis may match across link boundaries, link text cannot
/// contain nested links, and single `~` is never strikethrough (GFM allows it;
/// `~~` only here, matching remend).
enum InlineMarkdown {

  // MARK: - Style

  struct Style: Equatable {
    var fontSize: CGFloat
    var baseWeight: Font.Weight
    var strongWeight: Font.Weight
    var textColor: Color
    var codeScale: CGFloat
    /// nil → inline code uses `textColor`.
    var codeColor: Color?
    /// nil → no fill behind inline code.
    var codeBackground: Color?
    var linkColor: Color
    /// `<mark>` highlight fill.
    var markHighlight: Color = Color.yellow.opacity(0.30)
    /// `<kbd>` key-chip fill.
    var kbdBackground: Color = Color.primary.opacity(0.10)
    /// Whole-block italics (block quotes). Carried in the style — a SwiftUI
    /// `.italic()` view modifier can't reach the UIKit-backed selectable path.
    var italic: Bool = false
  }

  // MARK: - Trait Runs

  /// A maximal run of text sharing one trait set. The testable layer: the
  /// differential tests compare these against a swift-markdown oracle without
  /// involving fonts or colors.
  struct TraitRun: Equatable {
    var text: String
    var bold = false
    var italic = false
    var code = false
    var strikethrough = false
    /// `<kbd>` — a keyboard-key chip (monospaced + faint background fill).
    var kbd = false
    /// `<sup>` — superscript (raised baseline, smaller).
    var superscript = false
    /// `<sub>` — subscript (lowered baseline, smaller).
    var subscriptt = false
    /// `<ins>` / `<u>` — underline.
    var underline = false
    /// `<mark>` — highlighted text (background fill).
    var mark = false
    /// Link destination, when part of a *complete* link.
    var linkDestination: String? = nil
    /// True for any link text, including inert tail links that have no
    /// destination yet. Drives link coloring.
    var isLink = false
  }

  // MARK: - Public API

  static func traitRuns(_ markdown: String, isTail: Bool = false) -> [TraitRun] {
    guard !markdown.isEmpty else { return [] }
    if let plain = plainTraitRunsFastPath(markdown, isTail: isTail) { return plain }
    let chars = Array(markdown)
    var tokens: [Token] = []
    var delims: [Delim] = []
    tokens.reserveCapacity(min(chars.count / 4 + 1, 64))
    tokenize(
      chars, isTail: isTail, linksEnabled: true,
      tokens: &tokens, delims: &delims
    )
    let spans = resolveEmphasis(tokens: tokens, delims: &delims, isTail: isTail)
    return emit(tokens: tokens, delims: delims, spans: spans)
  }

  /// Fast path for prose with no tokenizer-triggering ASCII. Strings containing
  /// any possible syntax marker fall through to the full streaming-tolerant parser.
  private static func plainTraitRunsFastPath(_ markdown: String, isTail: Bool) -> [TraitRun]? {
    var hasEntity = false
    var previousWasBang = false
    for byte in markdown.utf8 {
      if previousWasBang, byte == 91 { return nil }  // ![
      switch byte {
      case 38:  // &
        hasEntity = true
      case 33:  // !
        previousWasBang = true
        continue
      case 60, 91, 92, 96, 42, 95, 126:  // < [ \ ` * _ ~
        return nil
      default:
        previousWasBang = false
      }
    }
    if isTail, previousWasBang { return nil }
    return [TraitRun(text: hasEntity ? decodeEntities(markdown) : markdown)]
  }

  /// True when the tail-tolerant parse of `markdown` would draw no glyphs —
  /// the fragment is only incomplete markers ("**", "`", a held-back dash run
  /// that may still become a thematic break) and/or whitespace. Used by the
  /// streaming renderer to give such blocks ZERO height, so the block
  /// parser's speculative re-typing (paragraph "3" merging into a list once
  /// "3." arrives, "-"→"--"→"---" becoming a rule) inserts and removes only
  /// flat rows instead of shifting layout.
  ///
  /// Bounded: anything longer than a fragment always renders, so the full
  /// parse only runs on short tails.
  static func rendersEmpty(_ markdown: String) -> Bool {
    if markdown.isEmpty { return true }
    // Block-marker prefixes the inline parse can't know about: 1–2 chars of
    // -/_/* are a thematic break (or list marker) still arriving.
    if markdown.count <= 2, markdown.allSatisfy({ "-_*~`".contains($0) }) { return true }
    // An HTML tag still arriving ("<", "<deta", "</det") draws nothing yet —
    // give it zero height so it never flashes a literal "<" before completing.
    if markdown.first == "<", !markdown.utf8.contains(0x3E),
      markdown.dropFirst().allSatisfy({ $0.isLetter || $0 == "/" })
    {
      return true
    }
    guard markdown.count <= 24 else { return false }
    return traitRuns(markdown, isTail: true).allSatisfy { run in
      run.text.allSatisfy(\.isWhitespace)
    }
  }

  static func attributedString(
    _ markdown: String, style: Style, isTail: Bool = false
  ) -> AttributedString {
    var out = AttributedString()
    for run in traitRuns(markdown, isTail: isTail) {
      var piece = AttributedString(run.text)
      piece.mergeAttributes(attributes(for: run, style: style))
      out += piece
    }
    return out
  }

  // MARK: - Attribute mapping

  private static func attributes(for run: TraitRun, style: Style) -> AttributeContainer {
    var container = AttributeContainer()

    // `<kbd>` and `<code>` both render monospaced; `<sup>`/`<sub>` shrink and
    // shift their baseline.
    let mono = run.code || run.kbd
    let scriptScale: CGFloat = (run.superscript || run.subscriptt) ? 0.75 : 1
    let size = style.fontSize * (mono ? style.codeScale : 1) * scriptScale

    if mono {
      container.font = .system(
        size: size,
        weight: run.bold ? style.strongWeight : style.baseWeight,
        design: .monospaced
      )
      container.foregroundColor = style.codeColor ?? style.textColor
      if run.kbd {
        container.backgroundColor = style.kbdBackground
      } else if let bg = style.codeBackground {
        container.backgroundColor = bg
      }
    } else {
      var font = Font.system(
        size: size,
        weight: run.bold ? style.strongWeight : style.baseWeight
      )
      if run.italic || style.italic { font = font.italic() }
      container.font = font
      container.foregroundColor = run.isLink ? style.linkColor : style.textColor
    }

    if run.mark {
      container.backgroundColor = style.markHighlight
    }
    if run.superscript {
      container.baselineOffset = style.fontSize * 0.35
    } else if run.subscriptt {
      container.baselineOffset = -style.fontSize * 0.18
    }
    if run.underline {
      container.underlineStyle = .single
    }

    if run.isLink, let dest = run.linkDestination, let url = URL(string: dest) {
      container.link = url
    }
    if run.strikethrough {
      container.strikethroughStyle = .single
    }
    return container
  }

  // MARK: - Tokens

  private enum Token {
    /// Literal text, escapes already resolved.
    case text(String)
    /// Atomic code span content.
    case code(String)
    /// Start of link text. `destination == nil` for inert (incomplete) links.
    case linkOpen(destination: String?, complete: Bool)
    case linkClose
    /// Index into the delims array.
    case delim(Int)
    /// Inline HTML format tag (`<kbd>`, `<sup>`, `<b>`, …). Passthrough for the
    /// emphasis resolver — the format is applied via a stack in `emit`, exactly
    /// like `linkOpen`/`linkClose`.
    case htmlOpen(HTMLInlineFormat)
    case htmlClose(HTMLInlineFormat)
  }

  /// The inline trait a recognized HTML tag applies. `<code>` reuses the code
  /// trait; `<del>`/`<s>` reuse strikethrough; the rest are new.
  enum HTMLInlineFormat {
    case bold, italic, code, strike, kbd, sup, sub, underline, mark
  }

  private struct Delim {
    let ch: Character
    var count: Int
    let origCount: Int
    let canOpen: Bool
    let canClose: Bool
    let tokenIndex: Int
    /// The run's last character is the last character of the input.
    let touchesEnd: Bool
    var removed = false
  }

  private struct Span {
    let openTok: Int
    /// `Int.max` = auto-closed at end of input (tail tolerance).
    let closeTok: Int
    let kind: Kind
    enum Kind { case strong, em, strike }
  }

  // MARK: - Tokenizer

  /// Scans `chars` into a flat token stream. Code spans and links are extracted
  /// here (they bind tighter than emphasis); emphasis delimiter runs are
  /// recorded with their flanking properties for the matching pass.
  /// Explicit cap on link/image-text recursion. Today the parser is ALREADY
  /// bounded here: it recurses into link text / image alt with `linksEnabled:
  /// false`, so nested `[...]` render as literal text instead of recursing — the
  /// effective depth never exceeds ~2. This cap is defense-in-depth: if that
  /// invariant is ever changed (links enabled inside links), recursion stays
  /// bounded and degrades to literal text rather than overflowing the stack and
  /// crashing. Real prose never nests anywhere near this deep.
  private static let maxNestingDepth = 32

  private static func tokenize(
    _ chars: [Character],
    isTail: Bool,
    linksEnabled: Bool,
    tokens: inout [Token],
    delims: inout [Delim],
    depth: Int = 0
  ) {
    // Past the nesting cap, stop descending and emit whatever's left as literal
    // text — graceful degradation instead of an unbounded recursive crash.
    guard depth < maxNestingDepth else {
      if !chars.isEmpty { tokens.append(.text(String(chars))) }
      return
    }
    let n = chars.count
    var text: [Character] = []
    text.reserveCapacity(min(n, 64))
    var i = 0

    func flushText() {
      if !text.isEmpty {
        tokens.append(.text(String(text)))
        text.removeAll(keepingCapacity: true)
      }
    }

    while i < n {
      let c = chars[i]

      // Backslash escape: ASCII punctuation renders literally.
      if c == "\\", i + 1 < n {
        let next = chars[i + 1]
        if next.isASCII, isPunctuationOrSymbol(next) {
          text.append(next)
        } else {
          text.append(c)
          text.append(next)
        }
        i += 2
        continue
      }
      // Trailing backslash at the tail: hide (an escape may be arriving).
      if c == "\\", i + 1 == n, isTail {
        i += 1
        continue
      }

      // --- Inline HTML tags (<kbd>, <sup>, <b>, <br>, comments) ---
      if c == "<" {
        switch scanInlineTag(chars, at: i, isTail: isTail) {
        case .format(let format, let close, let end):
          flushText()
          tokens.append(close ? .htmlClose(format) : .htmlOpen(format))
          i = end
          continue
        case .lineBreak(let end):
          // `<br>` is a hard line break within the block.
          text.append("\n")
          i = end
          continue
        case .comment(let end):
          // HTML comment renders nothing.
          flushText()
          i = end
          continue
        case .hideToEnd:
          // Tail with a half-typed tag ("<kb", "<!--"): hide until it completes.
          flushText()
          i = n
          continue
        case .notATag:
          // A bare "<" (generics like Map<String>, "a < b", an unknown tag):
          // literal.
          text.append(c)
          i += 1
          continue
        }
      }

      // --- Code spans ---
      if c == "`" {
        var runEnd = i
        while runEnd < n, chars[runEnd] == "`" { runEnd += 1 }
        let runLen = runEnd - i

        if let close = backtickRun(chars, from: runEnd, length: runLen) {
          flushText()
          let content = codeSpanContent(Array(chars[runEnd..<close]))
          tokens.append(.code(content))
          i = close + runLen
        } else if isTail {
          // Auto-close to end. Empty content (dangling backticks) → hidden.
          flushText()
          let content = codeSpanContent(Array(chars[runEnd...]))
          if !content.isEmpty { tokens.append(.code(content)) }
          i = n
        } else {
          text.append(contentsOf: chars[i..<runEnd])
          i = runEnd
        }
        continue
      }

      // --- Images ---
      if c == "!", i + 1 < n, chars[i + 1] == "[", linksEnabled {
        if let closeBracket = matchingBracket(chars, openIndex: i + 1) {
          let alt = Array(chars[(i + 2)..<closeBracket])
          if closeBracket + 1 < n, chars[closeBracket + 1] == "(" {
            if let closeParen = matchingParen(chars, openIndex: closeBracket + 1) {
              // Complete image: render the alt text (no attachment support in
              // chat prose; matches the attributed experimental path).
              flushText()
              tokenize(alt, isTail: false, linksEnabled: false, tokens: &tokens, delims: &delims, depth: depth + 1)
              i = closeParen + 1
              continue
            }
            if isTail {
              // "![alt](partial…" → hide entirely until complete.
              flushText()
              i = n
              continue
            }
          }
          // "![alt]" with no "(": literal.
          text.append(contentsOf: chars[i...closeBracket])
          i = closeBracket + 1
          continue
        }
        if isTail {
          // "![al…" → hide.
          flushText()
          i = n
          continue
        }
        text.append(c)
        i += 1
        continue
      }
      // Lone "!" at the very end of the tail: an image may be arriving.
      if c == "!", i + 1 == n, isTail, linksEnabled {
        i += 1
        continue
      }

      // --- Links ---
      if c == "[", linksEnabled {
        if let closeBracket = matchingBracket(chars, openIndex: i) {
          let inner = Array(chars[(i + 1)..<closeBracket])
          if closeBracket + 1 < n, chars[closeBracket + 1] == "(" {
            if let closeParen = matchingParen(chars, openIndex: closeBracket + 1) {
              let dest = destination(Array(chars[(closeBracket + 2)..<closeParen]))
              flushText()
              tokens.append(.linkOpen(destination: dest, complete: true))
              tokenize(inner, isTail: false, linksEnabled: false, tokens: &tokens, delims: &delims, depth: depth + 1)
              tokens.append(.linkClose)
              i = closeParen + 1
              continue
            }
            if isTail {
              // "[text](partial-url…" → inert link to end.
              flushText()
              tokens.append(.linkOpen(destination: nil, complete: false))
              tokenize(inner, isTail: false, linksEnabled: false, tokens: &tokens, delims: &delims, depth: depth + 1)
              tokens.append(.linkClose)
              i = n
              continue
            }
          }
          if isTail, closeBracket == n - 1 {
            // "[text]" flush at the end: "(url)" may still be arriving.
            flushText()
            tokens.append(.linkOpen(destination: nil, complete: false))
            tokenize(inner, isTail: false, linksEnabled: false, tokens: &tokens, delims: &delims, depth: depth + 1)
            tokens.append(.linkClose)
            i = n
            continue
          }
          // "[text]" mid-text with no "(": literal (no reference links in chat).
          text.append(contentsOf: chars[i...closeBracket])
          i = closeBracket + 1
          continue
        }
        if isTail {
          // "[partial text…" → inert link to end.
          flushText()
          tokens.append(.linkOpen(destination: nil, complete: false))
          let inner = i + 1 < n ? Array(chars[(i + 1)...]) : []
          tokenize(inner, isTail: true, linksEnabled: false, tokens: &tokens, delims: &delims, depth: depth + 1)
          tokens.append(.linkClose)
          i = n
          continue
        }
        text.append(c)
        i += 1
        continue
      }

      // --- Emphasis delimiter runs ---
      if c == "*" || c == "_" || c == "~" {
        var runEnd = i
        while runEnd < n, chars[runEnd] == c { runEnd += 1 }
        let runLen = runEnd - i

        let prev: Character? = i > 0 ? chars[i - 1] : nil
        let next: Character? = runEnd < n ? chars[runEnd] : nil
        let flanking = flankingProperties(prev: prev, next: next)

        var canOpen: Bool
        var canClose: Bool
        switch c {
        case "*":
          canOpen = flanking.left
          canClose = flanking.right
        case "_":
          canOpen = flanking.left && (!flanking.right || flanking.prevPunct)
          canClose = flanking.right && (!flanking.left || flanking.nextPunct)
        default:  // "~" — GFM strikethrough, exactly two tildes.
          canOpen = flanking.left && runLen == 2
          canClose = flanking.right && runLen == 2
        }

        flushText()
        delims.append(
          Delim(
            ch: c, count: runLen, origCount: runLen,
            canOpen: canOpen, canClose: canClose,
            tokenIndex: tokens.count,
            touchesEnd: runEnd == n
          ))
        tokens.append(.delim(delims.count - 1))
        i = runEnd
        continue
      }

      text.append(c)
      i += 1
    }

    flushText()
  }

  private struct Flanking {
    let left: Bool
    let right: Bool
    let prevPunct: Bool
    let nextPunct: Bool
  }

  /// cmark left-/right-flanking rules. Out-of-range neighbors count as
  /// whitespace (start/end of block behaves like a space).
  private static func flankingProperties(prev: Character?, next: Character?) -> Flanking {
    func isWS(_ c: Character?) -> Bool { c.map(isWhitespace) ?? true }
    func isPunct(_ c: Character?) -> Bool {
      guard let c else { return false }
      return isPunctuationOrSymbol(c)
    }
    let prevWS = isWS(prev), nextWS = isWS(next)
    let prevPunct = isPunct(prev), nextPunct = isPunct(next)
    let left = !nextWS && (!nextPunct || prevWS || prevPunct)
    let right = !prevWS && (!prevPunct || nextWS || nextPunct)
    return Flanking(left: left, right: right, prevPunct: prevPunct, nextPunct: nextPunct)
  }

  @inline(__always)
  private static func isWhitespace(_ character: Character) -> Bool {
    guard let ascii = character.asciiValue else { return character.isWhitespace }
    return ascii == 0x20 || (ascii >= 0x09 && ascii <= 0x0D)
  }

  @inline(__always)
  private static func isPunctuationOrSymbol(_ character: Character) -> Bool {
    guard let ascii = character.asciiValue else {
      return character.isPunctuation || character.isSymbol
    }
    return (ascii >= 0x21 && ascii <= 0x2F)
      || (ascii >= 0x3A && ascii <= 0x40)
      || (ascii >= 0x5B && ascii <= 0x60)
      || (ascii >= 0x7B && ascii <= 0x7E)
  }

  // MARK: - Inline HTML scanning

  private enum InlineTagScan {
    /// A recognized formatting tag — `close` distinguishes `</b>` from `<b>`;
    /// `end` is the index just past the closing `>`.
    case format(HTMLInlineFormat, close: Bool, end: Int)
    /// `<br>` / `<br/>` — a hard line break.
    case lineBreak(end: Int)
    /// `<!-- … -->` — renders nothing.
    case comment(end: Int)
    /// Tail input with an unterminated tag — hide the remainder until it grows.
    case hideToEnd
    /// Not a recognized tag — the `<` is literal text.
    case notATag
  }

  /// Recognizes a small allowlist of inline HTML tags at `chars[i] == "<"`.
  /// Anything else (generics, comparisons, unknown/block tags) returns
  /// `.notATag` so the `<` stays literal — only known tags with a proper
  /// closing `>` are consumed. Tail-tolerant: an unterminated known tag hides.
  private static func scanInlineTag(_ chars: [Character], at i: Int, isTail: Bool)
    -> InlineTagScan
  {
    let n = chars.count

    // HTML comment.
    if i + 3 < n, chars[i + 1] == "!", chars[i + 2] == "-", chars[i + 3] == "-" {
      var j = i + 4
      while j + 2 < n {
        if chars[j] == "-", chars[j + 1] == "-", chars[j + 2] == ">" {
          return .comment(end: j + 3)
        }
        j += 1
      }
      return isTail ? .hideToEnd : .notATag
    }

    var j = i + 1
    var close = false
    if j < n, chars[j] == "/" {
      close = true
      j += 1
    }

    let nameStart = j
    while j < n, chars[j].isLetter || chars[j].isNumber { j += 1 }
    guard j > nameStart else { return .notATag }  // "<" not followed by a name
    let name = String(chars[nameStart..<j]).lowercased()
    guard let tag = inlineTag(named: name) else { return .notATag }  // unknown → literal

    // Skip any attributes up to the closing ">" (inline tags here carry none
    // with a literal ">").
    while j < n, chars[j] != ">" { j += 1 }
    guard j < n else { return isTail ? .hideToEnd : .notATag }
    let end = j + 1

    switch tag {
    case .br: return .lineBreak(end: end)
    case .format(let format): return .format(format, close: close, end: end)
    }
  }

  private enum InlineTag {
    case format(HTMLInlineFormat)
    case br
  }

  private static func inlineTag(named name: String) -> InlineTag? {
    switch name {
    case "b", "strong": return .format(.bold)
    case "i", "em": return .format(.italic)
    case "code": return .format(.code)
    case "del", "s", "strike": return .format(.strike)
    case "kbd": return .format(.kbd)
    case "sup": return .format(.sup)
    case "sub": return .format(.sub)
    case "ins", "u": return .format(.underline)
    case "mark": return .format(.mark)
    case "br": return .br
    default: return nil
    }
  }

  /// Decodes the common named/numeric HTML entities that appear in agent HTML
  /// (`&lt;`, `&gt;`, `&amp;`, `&quot;`, `&#39;`, `&nbsp;`). `&amp;` is decoded
  /// last so `&amp;lt;` round-trips to `&lt;`. CommonMark decodes entities in
  /// text too, so this also nudges plain markdown toward the oracle.
  static func decodeEntities(_ s: String) -> String {
    guard s.utf8.contains(0x26) else { return s }
    var out = s
    out = out.replacingOccurrences(of: "&lt;", with: "<")
    out = out.replacingOccurrences(of: "&gt;", with: ">")
    out = out.replacingOccurrences(of: "&quot;", with: "\"")
    out = out.replacingOccurrences(of: "&#39;", with: "'")
    out = out.replacingOccurrences(of: "&apos;", with: "'")
    out = out.replacingOccurrences(of: "&nbsp;", with: "\u{00A0}")
    out = out.replacingOccurrences(of: "&amp;", with: "&")
    return out
  }

  // MARK: - Emphasis resolution

  /// cmark's delimiter-stack "process emphasis" algorithm, plus the tail
  /// tolerance pass for streaming input.
  private static func resolveEmphasis(
    tokens: [Token], delims: inout [Delim], isTail: Bool
  ) -> [Span] {
    var spans: [Span] = []
    spans.reserveCapacity(min(delims.count / 2, 16))

    var ci = 0
    while ci < delims.count {
      let closer = delims[ci]
      guard closer.canClose, closer.count > 0, !closer.removed else {
        ci += 1
        continue
      }

      // Nearest valid opener to the left.
      var found = -1
      var oi = ci - 1
      while oi >= 0 {
        let o = delims[oi]
        if !o.removed, o.count > 0, o.ch == closer.ch, o.canOpen,
          ruleOfThreeAllows(opener: o, closer: closer)
        {
          found = oi
          break
        }
        oi -= 1
      }
      guard found >= 0 else {
        ci += 1
        continue
      }

      if closer.ch == "~" {
        spans.append(
          Span(
            openTok: delims[found].tokenIndex,
            closeTok: delims[ci].tokenIndex,
            kind: .strike
          ))
        delims[found].count = 0
        delims[ci].count = 0
      } else {
        let use = (delims[found].count >= 2 && delims[ci].count >= 2) ? 2 : 1
        spans.append(
          Span(
            openTok: delims[found].tokenIndex,
            closeTok: delims[ci].tokenIndex,
            kind: use == 2 ? .strong : .em
          ))
        delims[found].count -= use
        delims[ci].count -= use
      }

      // Delimiters strictly between a matched pair can no longer participate.
      if found + 1 < ci {
        for k in (found + 1)..<ci { delims[k].removed = true }
      }

      if delims[ci].count == 0 { ci += 1 }
      // else: the same closer keeps matching earlier openers.
    }

    guard isTail else { return spans }

    // Tail tolerance for leftover (unmatched) delimiter runs:
    // 1. A run touching the very end is hidden — the next chunk decides
    //    whether it opens emphasis or stays literal ("word **").
    // 2. An unmatched opener with renderable content after it auto-closes at
    //    the end of input, markers hidden ("**bold and more").
    // 3. Anything else keeps settled (literal) semantics.
    for di in delims.indices {
      let d = delims[di]
      guard d.count > 0 else { continue }

      if d.touchesEnd {
        delims[di].count = 0
        continue
      }
      guard d.canOpen, !d.removed,
        hasRenderableContent(tokens: tokens, after: d.tokenIndex)
      else { continue }

      if d.ch == "~" {
        if d.count == 2 {
          spans.append(Span(openTok: d.tokenIndex, closeTok: .max, kind: .strike))
          delims[di].count = 0
        }
      } else {
        if d.count >= 2 {
          spans.append(Span(openTok: d.tokenIndex, closeTok: .max, kind: .strong))
        }
        if d.count == 1 || d.count >= 3 {
          spans.append(Span(openTok: d.tokenIndex, closeTok: .max, kind: .em))
        }
        delims[di].count = 0
      }
    }

    return spans
  }

  /// cmark "rule of three": when a delimiter run can both open and close,
  /// it cannot pair with another if their combined length is a multiple of 3,
  /// unless both lengths are themselves multiples of 3.
  private static func ruleOfThreeAllows(opener: Delim, closer: Delim) -> Bool {
    guard opener.ch != "~" else { return true }
    if closer.canOpen || opener.canClose {
      if (opener.origCount + closer.origCount) % 3 == 0,
        !(opener.origCount % 3 == 0 && closer.origCount % 3 == 0)
      {
        return false
      }
    }
    return true
  }

  private static func hasRenderableContent(tokens: [Token], after index: Int) -> Bool {
    guard index + 1 < tokens.count else { return false }
    for token in tokens[(index + 1)...] {
      switch token {
      case .text(let s):
        if !s.allSatisfy(\.isWhitespace) { return true }
      case .code, .linkOpen:
        return true
      case .linkClose, .delim, .htmlOpen, .htmlClose:
        continue
      }
    }
    return false
  }

  // MARK: - Emission

  private static func emit(tokens: [Token], delims: [Delim], spans: [Span]) -> [TraitRun] {
    var runs: [TraitRun] = []
    runs.reserveCapacity(min(tokens.count, 32))
    var linkDepth = 0
    var linkDestination: String?
    let hasSpans = !spans.isEmpty
    var opens: [[Span.Kind]] = []
    var closes: [[Span.Kind]] = []
    if hasSpans {
      opens = Array(repeating: [], count: tokens.count)
      closes = Array(repeating: [], count: tokens.count)
      for span in spans {
        let openIndex = span.openTok + 1
        if openIndex < tokens.count { opens[openIndex].append(span.kind) }
        if span.closeTok < tokens.count { closes[span.closeTok].append(span.kind) }
      }
    }
    var boldDepth = 0
    var italicDepth = 0
    var strikeDepth = 0
    // Active inline HTML formats, innermost last (push on open, pop matching on
    // close). OR'd into every run while open, like the link state above.
    var htmlStack: [HTMLInlineFormat] = []

    func append(_ text: String, code: Bool, at tokenIndex: Int) {
      guard !text.isEmpty else { return }
      var run = TraitRun(
        // Backtick code spans stay literal (CommonMark doesn't decode entities
        // inside them); plain text and `<code>` HTML content are decoded.
        text: code ? text : decodeEntities(text),
        bold: boldDepth > 0,
        italic: italicDepth > 0,
        code: code,
        strikethrough: strikeDepth > 0,
        linkDestination: linkDepth > 0 ? linkDestination : nil,
        isLink: linkDepth > 0
      )
      // Layer the active HTML formats on top of the markdown traits.
      for format in htmlStack {
        switch format {
        case .bold: run.bold = true
        case .italic: run.italic = true
        case .code: run.code = true
        case .strike: run.strikethrough = true
        case .kbd: run.kbd = true
        case .sup: run.superscript = true
        case .sub: run.subscriptt = true
        case .underline: run.underline = true
        case .mark: run.mark = true
        }
      }
      // Merge with the previous run when only the text differs.
      if var last = runs.last,
        last.bold == run.bold, last.italic == run.italic, last.code == run.code,
        last.strikethrough == run.strikethrough, last.kbd == run.kbd,
        last.superscript == run.superscript, last.subscriptt == run.subscriptt,
        last.underline == run.underline, last.mark == run.mark,
        last.linkDestination == run.linkDestination, last.isLink == run.isLink
      {
        last.text += run.text
        runs[runs.count - 1] = last
      } else {
        runs.append(run)
      }
    }

    for (index, token) in tokens.enumerated() {
      if hasSpans, !closes[index].isEmpty {
        for kind in closes[index] {
          switch kind {
          case .strong: boldDepth = max(0, boldDepth - 1)
          case .em: italicDepth = max(0, italicDepth - 1)
          case .strike: strikeDepth = max(0, strikeDepth - 1)
          }
        }
      }
      if hasSpans, !opens[index].isEmpty {
        for kind in opens[index] {
          switch kind {
          case .strong: boldDepth += 1
          case .em: italicDepth += 1
          case .strike: strikeDepth += 1
          }
        }
      }
      switch token {
      case .text(let s):
        append(s, code: false, at: index)
      case .code(let s):
        append(s, code: true, at: index)
      case .linkOpen(let destination, _):
        linkDepth += 1
        linkDestination = destination
      case .linkClose:
        linkDepth = max(0, linkDepth - 1)
        if linkDepth == 0 { linkDestination = nil }
      case .htmlOpen(let format):
        htmlStack.append(format)
      case .htmlClose(let format):
        // Pop the innermost matching tag; tolerate stray/mismatched closers.
        if let idx = htmlStack.lastIndex(of: format) {
          htmlStack.remove(at: idx)
        }
      case .delim(let di):
        let d = delims[di]
        if d.count > 0 {
          append(String(repeating: d.ch, count: d.count), code: false, at: index)
        }
      }
    }

    return runs
  }

  // MARK: - Scanning helpers

  /// Start index of the next backtick run of *exactly* `length`, or nil.
  private static func backtickRun(_ chars: [Character], from: Int, length: Int) -> Int? {
    var j = from
    let n = chars.count
    while j < n {
      if chars[j] == "`" {
        let start = j
        while j < n, chars[j] == "`" { j += 1 }
        if j - start == length { return start }
      } else {
        j += 1
      }
    }
    return nil
  }

  /// cmark code-span normalization: newlines become spaces; one leading and
  /// trailing space are stripped when both exist and the content isn't all
  /// spaces (lets you write `` ` `` to show a backtick).
  private static func codeSpanContent(_ chars: [Character]) -> String {
    var content = String(chars).replacingOccurrences(of: "\n", with: " ")
    if content.count >= 2, content.hasPrefix(" "), content.hasSuffix(" "),
      !content.allSatisfy({ $0 == " " })
    {
      content = String(content.dropFirst().dropLast())
    }
    return content
  }

  /// Index of the `]` matching the `[` at `openIndex` (escape- and depth-aware).
  private static func matchingBracket(_ chars: [Character], openIndex: Int) -> Int? {
    var depth = 1
    var j = openIndex + 1
    let n = chars.count
    while j < n {
      switch chars[j] {
      case "\\": j += 1
      case "[": depth += 1
      case "]":
        depth -= 1
        if depth == 0 { return j }
      default: break
      }
      j += 1
    }
    return nil
  }

  /// Index of the `)` matching the `(` at `openIndex` (escape- and depth-aware).
  private static func matchingParen(_ chars: [Character], openIndex: Int) -> Int? {
    var depth = 1
    var j = openIndex + 1
    let n = chars.count
    while j < n {
      switch chars[j] {
      case "\\": j += 1
      case "(": depth += 1
      case ")":
        depth -= 1
        if depth == 0 { return j }
      default: break
      }
      j += 1
    }
    return nil
  }

  /// Extracts the destination from link-parenthesis content: strips an
  /// optional `<...>` wrapper, drops a quoted title after whitespace.
  private static func destination(_ chars: [Character]) -> String? {
    var s = String(chars).trimmingCharacters(in: .whitespacesAndNewlines)
    if s.hasPrefix("<"), let end = s.firstIndex(of: ">") {
      s = String(s[s.index(after: s.startIndex)..<end])
    } else if let ws = s.firstIndex(where: \.isWhitespace) {
      s = String(s[..<ws])
    }
    return s.isEmpty ? nil : s
  }
}

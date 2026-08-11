import Foundation
import JavaScriptCore
import SwiftUI
import UIKit

// MARK: - Engine (shared, actor-isolated)

/// Syntax highlighting for CustomMarkdown code blocks, backed by the app's
/// existing Highlightr dependency (highlight.js over JavaScriptCore).
///
/// Actor-isolated on purpose: a JSContext is not thread-safe, and this keeps
/// all highlighting work off the main thread — the word-fade renderer ticks
/// at 60fps while code streams, so main-thread highlight stalls would drop
/// animation frames. Owns its own Highlightr instances rather than sharing
/// `DiffHighlighter`'s (ToolCallView), which are called synchronously on the
/// main thread by diff rows; sharing one JSContext across both would race.
actor CodeBlockHighlighter {
  static let shared = CodeBlockHighlighter()

  /// Blocks bigger than this render plain — highlight.js cost grows
  /// super-linearly and a wall of code doesn't need colors to be readable.
  static let maxHighlightableLength = 30_000

  // We run highlight.js ourselves (the bundled `highlight.min.js`, the same file
  // Highlightr ships) and color the `hljs-*` spans from `SyntaxTheme` — the
  // shared palette in `packages/syntax-theme` (CodeMirror/VSCode is king). This
  // makes iOS markdown match the web markdown surface exactly; Highlightr's own
  // theming can't be fed custom CSS (its Theme init is internal).
  private lazy var context: JSContext? = Self.makeContext()

  private static func makeContext() -> JSContext? {
    guard let ctx = JSContext(),
      let path = Bundle.module.path(forResource: "highlight.min", ofType: "js"),
      let js = try? String(contentsOfFile: path, encoding: .utf8)
    else { return nil }
    ctx.evaluateScript(js)
    // Helper: highlight with an explicit (registered) language, else auto-detect
    // — mirrors CodeBlock passing nil for bare ``` fences. Returns null on error.
    ctx.evaluateScript("""
      function __rgHighlight(code, lang) {
        try {
          if (lang && hljs.getLanguage(lang)) {
            return hljs.highlight(code, { language: lang, ignoreIllegals: true }).value;
          }
          return hljs.highlightAuto(code).value;
        } catch (e) { return null; }
      }
      """)
    return ctx
  }

  /// Highlights `code` and returns an AttributedString carrying per-run
  /// foreground colors only (CodeStreamingText supplies the font). `language:
  /// nil` lets highlight.js auto-detect. The plain text round-trips verbatim, so
  /// the caller's line-count check stays valid.
  func highlight(_ code: String, language: String?, dark: Bool) -> AttributedString? {
    guard !code.isEmpty, code.count <= Self.maxHighlightableLength else { return nil }
    guard let ctx = context, let fn = ctx.objectForKeyedSubscript("__rgHighlight") else {
      return nil
    }
    let args: [Any] = [code, language.map { $0 as Any } ?? NSNull()]
    let result = fn.call(withArguments: args)
    guard let html = result?.toString(), !html.isEmpty, html != "undefined", html != "null"
    else { return nil }
    return Self.parse(html: html, dark: dark)
  }

  // MARK: - HTML span parsing

  /// Parses highlight.js output (`<span class="hljs-…">` + escaped text) into an
  /// AttributedString, coloring each run by the innermost mapped scope.
  private static func parse(html: String, dark: Bool) -> AttributedString {
    let result = NSMutableAttributedString()
    var stack: [[String]] = []
    var text = ""

    func flush() {
      guard !text.isEmpty else { return }
      let fallback = dark ? SyntaxTheme.defaultForeground.dark : SyntaxTheme.defaultForeground.light
      let color = colorForStack(stack, dark: dark) ?? fallback
      result.append(
        NSAttributedString(
          string: decodeEntities(text),
          attributes: [.foregroundColor: uiColor(color)]))
      text = ""
    }

    var i = html.startIndex
    while i < html.endIndex {
      let ch = html[i]
      if ch == "<" {
        flush()
        guard let gt = html[i...].firstIndex(of: ">") else { break }
        let tag = html[html.index(after: i)..<gt]
        if tag.hasPrefix("/") {
          if !stack.isEmpty { stack.removeLast() }
        } else {
          stack.append(classes(in: tag))
        }
        i = html.index(after: gt)
      } else {
        text.append(ch)
        i = html.index(after: i)
      }
    }
    flush()
    return AttributedString(result)
  }

  /// Innermost mapped scope wins; falls outward through the stack if a span has
  /// no mapped color (so e.g. `hljs-meta > hljs-string` colors as a string).
  private static func colorForStack(_ stack: [[String]], dark: Bool) -> UInt32? {
    for classList in stack.reversed() {
      if classList.contains("class_") { return SyntaxTheme.color(forScope: "class_", dark: dark) }
      if classList.contains("function_") {
        return SyntaxTheme.color(forScope: "function_", dark: dark)
      }
      for cls in classList where cls.hasPrefix("hljs-") {
        if let c = SyntaxTheme.color(forScope: String(cls.dropFirst(5)), dark: dark) { return c }
      }
    }
    return nil
  }

  private static func classes(in tag: Substring) -> [String] {
    guard let r = tag.range(of: "class=\"") else { return [] }
    let rest = tag[r.upperBound...]
    guard let close = rest.firstIndex(of: "\"") else { return [] }
    return rest[..<close].split(separator: " ").map(String.init)
  }

  /// Decodes the entities highlight.js emits. `&amp;` is replaced last so a
  /// literal `&lt;` (encoded `&amp;lt;`) survives intact.
  private static func decodeEntities(_ s: String) -> String {
    guard s.contains("&") else { return s }
    var r = s
    r = r.replacingOccurrences(of: "&lt;", with: "<")
    r = r.replacingOccurrences(of: "&gt;", with: ">")
    r = r.replacingOccurrences(of: "&quot;", with: "\"")
    r = r.replacingOccurrences(of: "&#x27;", with: "'")
    r = r.replacingOccurrences(of: "&#39;", with: "'")
    r = r.replacingOccurrences(of: "&amp;", with: "&")
    return r
  }

  private static func uiColor(_ hex: UInt32) -> UIColor {
    UIColor(
      red: CGFloat((hex >> 16) & 0xFF) / 255,
      green: CGFloat((hex >> 8) & 0xFF) / 255,
      blue: CGFloat(hex & 0xFF) / 255,
      alpha: 1)
  }
}

// MARK: - Per-block model (coalescing + throttling)

/// Drives async highlighting for one CodeBlock. The streaming discipline
/// (lifted from SwiftStreamingMarkdown's CodeBlockView):
///
/// - the block renders plain monospaced text immediately; colors arrive later
/// - requests coalesce **latest-wins**: while a highlight is in flight, newer
///   code replaces the pending job instead of queueing behind it
/// - streaming requests are throttled (`streamingThrottle`) so a fast stream
///   doesn't re-run highlight.js per flush; the settle pass runs immediately
@MainActor
@Observable
final class CodeBlockHighlightModel {

  /// Highlighted lines (split on newlines), aligned with the plain code's
  /// line array of the job they were produced from. Consumers must verify
  /// per-line text equality before using a line — during streaming this can
  /// lag the live code by a throttle interval.
  private(set) var highlightedLines: [AttributedString]?

  private struct Job {
    var code: String
    var language: String?
    var dark: Bool
    var throttle: TimeInterval
  }

  @ObservationIgnored private var pending: Job?
  @ObservationIgnored private var isRunning = false
  @ObservationIgnored private var lastRunDate = Date.distantPast
  @ObservationIgnored private var completedKey: String?

  // One reveal-cadence interval (`WordFadeEngine.wordStep`). Coalescing is
  // latest-wins, so this only caps how often highlight.js re-runs on the actor;
  // tighter than the fade so color lands close behind the streaming tail
  // instead of trailing it by a quarter second (the old 0.25s left a visible
  // window of un-highlighted, alpha-faded gray text).
  private static let streamingThrottle: TimeInterval = 0.12

  func setNeedsHighlight(code: String, language: String?, dark: Bool, throttled: Bool) {
    let key = Self.jobKey(code: code, language: language, dark: dark)
    guard key != completedKey else { return }
    pending = Job(
      code: code,
      language: language,
      dark: dark,
      throttle: throttled ? Self.streamingThrottle : 0
    )
    pump()
  }

  private func pump() {
    guard !isRunning, pending != nil else { return }
    isRunning = true
    Task { [weak self] in
      guard let self else { return }
      defer {
        self.isRunning = false
        self.pump()  // pick up anything that arrived while running
      }

      if let job = self.pending {
        let wait = job.throttle - Date().timeIntervalSince(self.lastRunDate)
        if wait > 0 {
          try? await Task.sleep(for: .seconds(wait))
        }
      }
      // Latest wins: take whatever is pending AFTER the throttle wait.
      guard let job = self.pending else { return }
      self.pending = nil

      let result = await CodeBlockHighlighter.shared.highlight(
        job.code, language: job.language, dark: job.dark)
      self.lastRunDate = Date()
      self.completedKey = Self.jobKey(code: job.code, language: job.language, dark: job.dark)

      let lines = result.flatMap { Self.splitLines($0, matching: job.code) }
      if let lines {
        self.highlightedLines = lines
      }
    }
  }

  private static func jobKey(code: String, language: String?, dark: Bool) -> String {
    "\(dark ? "d" : "l")|\(language ?? "")|\(code.count)|\(code.hashValue)"
  }

  /// Splits the highlighted text on newlines and verifies the line count
  /// matches the plain code's — highlight.js round-trips the text verbatim,
  /// but if it ever doesn't, plain rendering wins over misaligned colors.
  private static func splitLines(
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
}

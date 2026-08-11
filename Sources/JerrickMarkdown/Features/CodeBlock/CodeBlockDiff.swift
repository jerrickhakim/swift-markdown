import Foundation
import Highlightr
import SwiftUI

// MARK: - Highlightr engine

enum DiffHighlighter {
  private static let lightInstance: Highlightr? = make(theme: "atom-one-light")
  private static let darkInstance: Highlightr? = make(theme: "atom-one-dark")

  private static func make(theme: String) -> Highlightr? {
    let h = Highlightr()
    _ = h?.setTheme(to: theme)
    h?.ignoreIllegals = true
    return h
  }

  /// Returns a SwiftUI `AttributedString` with foreground colors only — fonts
  /// and background colors from the Highlightr theme are stripped so the
  /// caller's row tinting and font choice win.
  static func highlight(_ code: String, language: String, dark: Bool) -> AttributedString? {
    guard !code.isEmpty else { return nil }
    let h = dark ? darkInstance : lightInstance
    guard let ns = h?.highlight(code, as: language, fastRender: true) else { return nil }
    let mutable = NSMutableAttributedString(attributedString: ns)
    let full = NSRange(location: 0, length: mutable.length)
    mutable.removeAttribute(.font, range: full)
    mutable.removeAttribute(.backgroundColor, range: full)
    return AttributedString(mutable)
  }
}

// MARK: - Unified Diff View

/// Renders a parsed unified diff as a gutter + `+`/`−` prefixed, syntax-tinted
/// list of rows. Used as the body of a `CodeBlock` in diff mode (the edit-tool
/// dropdown and any `diff`-fenced markdown block).
struct UnifiedDiffView: View {
  let lines: [MarkdownDiffLine]
  let language: String
  var theme: MarkdownTheme = .standard

  private var maxLineNumber: Int {
    var m = 1
    for l in lines {
      if let n = l.oldLineNumber, n > m { m = n }
      if let n = l.newLineNumber, n > m { m = n }
    }
    return m
  }

  private var gutterWidth: CGFloat {
    // Approx 7pt per digit at size 11 monospaced + padding.
    CGFloat(String(maxLineNumber).count) * 7.5 + 12
  }

  var body: some View {
    LazyVStack(alignment: .leading, spacing: 0) {
      ForEach(lines) { line in
        DiffRowView(
          line: line,
          language: language,
          gutterWidth: gutterWidth,
          theme: theme
        )
      }
    }
  }
}

private struct DiffRowView: View {
  let line: MarkdownDiffLine
  let language: String
  let gutterWidth: CGFloat
  let theme: MarkdownTheme
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    switch line.kind {
    case .hunk:
      HStack(spacing: 0) {
        Text(line.content)
          .font(.system(size: 11, weight: .medium, design: .monospaced))
          .foregroundStyle(theme.diff.secondaryText.resolve(for: colorScheme))
          .lineLimit(1)
          .padding(.leading, gutterWidth + 18)
          .padding(.trailing, 12)
        Spacer(minLength: 0)
      }
      .padding(.vertical, 6)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        theme.diff.surface.resolve(for: colorScheme).opacity(colorScheme == .dark ? 0.5 : 0.6)
      )

    default:
      HStack(alignment: .firstTextBaseline, spacing: 0) {
        Text(displayLineNumber.map(String.init) ?? "")
          .font(.system(size: 11, design: .monospaced))
          .foregroundStyle(gutterColor)
          .frame(width: gutterWidth, alignment: .trailing)
          .padding(.trailing, 4)

        Text(prefixSymbol)
          .font(.system(size: 12, weight: .bold, design: .monospaced))
          .foregroundStyle(prefixColor)
          .frame(width: 14, alignment: .center)

        codeText
          .font(.system(size: 12.5, design: .monospaced))
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.trailing, 12)
          .textSelection(.enabled)
      }
      .padding(.vertical, 2.5)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(rowBackground)
    }
  }

  // MARK: Per-row styling

  private var displayLineNumber: Int? {
    switch line.kind {
    case .addition, .context: return line.newLineNumber
    case .deletion: return line.oldLineNumber
    case .hunk: return nil
    }
  }

  private var prefixSymbol: String {
    switch line.kind {
    case .addition: return "+"
    case .deletion: return "−"
    case .context: return " "
    case .hunk: return ""
    }
  }

  private var prefixColor: Color {
    switch line.kind {
    case .addition: return theme.diff.addition.resolve(for: colorScheme)
    case .deletion: return theme.diff.deletion.resolve(for: colorScheme)
    default: return theme.diff.secondaryText.resolve(for: colorScheme).opacity(0.6)
    }
  }

  private var rowBackground: Color {
    switch line.kind {
    case .addition:
      return theme.diff.addition.resolve(for: colorScheme).opacity(
        colorScheme == .dark ? 0.16 : 0.13)
    case .deletion:
      return theme.diff.deletion.resolve(for: colorScheme).opacity(
        colorScheme == .dark ? 0.16 : 0.13)
    default: return .clear
    }
  }

  private var gutterColor: Color {
    switch line.kind {
    case .addition: return theme.diff.addition.resolve(for: colorScheme).opacity(0.75)
    case .deletion: return theme.diff.deletion.resolve(for: colorScheme).opacity(0.75)
    default: return theme.diff.secondaryText.resolve(for: colorScheme).opacity(0.7)
    }
  }

  @ViewBuilder
  private var codeText: some View {
    if line.content.isEmpty {
      Text(" ").foregroundStyle(theme.diff.text.resolve(for: colorScheme))
    } else if let attr = DiffHighlighter.highlight(
      line.content, language: language, dark: colorScheme == .dark)
    {
      Text(attr)
    } else {
      Text(line.content).foregroundStyle(theme.diff.text.resolve(for: colorScheme))
    }
  }
}

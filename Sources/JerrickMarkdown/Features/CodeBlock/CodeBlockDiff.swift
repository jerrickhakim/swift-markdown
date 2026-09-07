import Foundation
import SwiftUI

// MARK: - Row highlighting

enum DiffHighlighter {
  /// Colors one diff row through the shared native highlighter, so a row and a
  /// plain code block color an identical line identically. Foreground colors
  /// only — the caller owns the font and the add/delete row tint.
  static func highlight(_ code: String, language: String) -> AttributedString? {
    guard !code.isEmpty else { return nil }
    guard let lines = NativeSyntaxHighlighter.lines(code: code, language: language),
      lines.count == 1
    else { return nil }
    return lines.first
  }
}

// MARK: - Unified Diff View

/// Renders a parsed unified diff as a gutter + `+`/`−` prefixed, syntax-tinted
/// list of rows. Used as the body of a `CodeBlock` in diff mode — the edit-tool
/// dropdown. (A `diff`-fenced markdown block is a normal code block coloured by
/// `SyntaxMode.diff`, not this view.)
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
    } else if let attr = DiffHighlighter.highlight(line.content, language: language) {
      Text(attr)
    } else {
      Text(line.content).foregroundStyle(theme.diff.text.resolve(for: colorScheme))
    }
  }
}

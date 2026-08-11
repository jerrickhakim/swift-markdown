import SwiftUI

// MARK: - Details / Summary

/// HTML `<details>`/`<summary>` collapsible. A tappable summary row with a
/// rotating chevron reveals the body blocks below it.
///
/// Streaming: while the details is the tail, it stays expanded so the body
/// streams in visibly, and the last body block carries `isStreamingTail` so its
/// word fade runs. One view identity across the tail→settled flip preserves
/// the user's expand/collapse state. Settled history details honor the `<details open>` attribute
/// (collapsed unless `open`). Collapsed → body blocks aren't built, so a
/// closed details costs nothing.
struct MarkdownDetails: View {
    let summary: [MarkdownBlockContent]
    let blocks: [MarkdownBlockContent]
    let style: MarkdownStyle
    let theme: MarkdownTheme
    var isStreamingTail: Bool

  @State private var expanded: Bool
  @Environment(\.colorScheme) private var colorScheme

  init(
    summary: [MarkdownBlockContent],
    open: Bool,
    blocks: [MarkdownBlockContent],
    style: MarkdownStyle,
    theme: MarkdownTheme = .standard,
    isStreamingTail: Bool = false
  ) {
    self.summary = summary
    self.blocks = blocks
    self.style = style
    self.theme = theme
    self.isStreamingTail = isStreamingTail
    _expanded = State(initialValue: open || isStreamingTail)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      summaryRow

      if expanded, !blocks.isEmpty {
        HStack(alignment: .top, spacing: 0) {
          RoundedRectangle(cornerRadius: 1)
            .fill(theme.separator.resolve(for: colorScheme))
            .frame(width: 2)

          VStack(alignment: .leading, spacing: 0) {
            ForEach(blocks.indices, id: \.self) { i in
              CustomMarkdownBlock(
                block: blocks[i],
                style: style,
                theme: theme,
                isStreamingTail: isStreamingTail && i == blocks.count - 1
              )
            }
          }
          .padding(.leading, 12)
        }
        .padding(.top, 4)
        .padding(.leading, 6)
        // Fade in place while the container's height animates open. A `.move`
        // transition would slide the body up out of the (unclipped) parent and
        // overlap the summary; clipping the parent instead would crop nested
        // details mid-grow, so we keep the body in its slot and let the height
        // change carry the reveal.
        .transition(.opacity)
      }
    }
    .streamingChromeFade(isStreamingTail)
  }

  // MARK: Summary row

  private var summaryRow: some View {
    Button {
      withAnimation(.snappy(duration: 0.22)) { expanded.toggle() }
    } label: {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Image(systemName: "chevron.right")
          .font(.system(size: style.baseSize * 0.78, weight: .semibold))
          .foregroundStyle(.secondary)
          .rotationEffect(.degrees(expanded ? 90 : 0))
          // Baseline-align the chevron with the first line of summary text.
          .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }

        summaryContent

        Spacer(minLength: 0)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  /// The summary is rendered as plain SwiftUI `Text` (not the selectable
  /// UITextView) so taps reach the toggle button instead of starting a text
  /// selection. A single-paragraph summary (the common case) renders inline
  /// with full inline markup/HTML; a richer summary (e.g. a code block inside
  /// `<summary>`) falls back to the full block renderer.
  @ViewBuilder
  private var summaryContent: some View {
    if let text = singleParagraphSummary {
      Text(InlineMarkdown.attributedString(text, style: summaryStyle))
        .multilineTextAlignment(.leading)
    } else if summary.isEmpty {
      Text("Details")
        .font(.system(size: style.baseSize, weight: .semibold))
        .foregroundStyle(style.textColor)
    } else {
      VStack(alignment: .leading, spacing: 0) {
        ForEach(summary.indices, id: \.self) { i in
          CustomMarkdownBlock(block: summary[i], style: style, theme: theme)
        }
      }
    }
  }

  /// The text of a summary that is exactly one paragraph, else nil.
  private var singleParagraphSummary: String? {
    guard summary.count == 1, case .paragraph(let text, _) = summary[0] else { return nil }
    return text
  }

  /// Summaries read as a heading for the section — semibold by default; any
  /// inner `<strong>`/`**` still applies on top.
  private var summaryStyle: InlineMarkdown.Style {
    var inline = style.inline
    inline.baseWeight = .semibold
    return inline
  }
}

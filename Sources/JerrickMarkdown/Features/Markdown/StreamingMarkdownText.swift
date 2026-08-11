import SwiftUI

// MARK: - Streaming Markdown Text

/// Renders one block's inline markdown as a single selectable text view.
///
/// ONE view for both states: `SelectableMarkdownText` (a hardened UITextView)
/// renders streaming and settled blocks alike, so there is no tail→settled
/// view swap and therefore no settle layout shift, by construction. The
/// sequential word fade runs inside the text view (display-only color
/// animation driven by a CADisplayLink — see `SelectableTextView`); real
/// UIKit selection is available the moment a block settles.
///
/// This wrapper owns the one piece of streaming logic that is about *text*,
/// not rendering:
///
/// **Word holdback** — while this block is the streaming tail, the trailing
/// partial word is buffered until a word boundary arrives (locale-aware
/// `.byWords` segmentation, so CJK and other no-whitespace scripts commit at
/// real word boundaries too). A half-streamed word never sits at the end of a
/// line and then jumps to the next one when it grows. When the stream ends,
/// the holdback releases: the full text flows in as one final growth and
/// fades like any other.
struct StreamingMarkdownText: View {
  let markdown: String
  let style: InlineMarkdown.Style
  var isStreamingTail: Bool = false
  var lineSpacing: CGFloat = 5
  /// Horizontal alignment (HTML `<p align>` / `<h3 align>`); markdown is always
  /// `.leading`.
  var alignment: MarkdownAlignment = .leading

  var body: some View {
    SelectableMarkdownText(
      markdown: isStreamingTail ? String(Self.committedPrefix(of: markdown)) : markdown,
      style: style,
      lineSpacing: lineSpacing,
      isStreaming: isStreamingTail,
      alignment: alignment
    )
    .frame(maxWidth: .infinity, alignment: frameAlignment)
  }

  private var frameAlignment: Alignment {
    switch alignment {
    case .leading: return .leading
    case .center: return .center
    case .trailing: return .trailing
    }
  }

  // MARK: - Word holdback

  /// Longest fragment we'll hold back. Past this, commit anyway so degenerate
  /// unsegmentable text (long URLs/identifiers) still streams.
  static let holdbackCap = 24

  /// How far back from the end to look for the last word boundary. Bounded so
  /// the per-flush cost stays O(window), not O(accumulated text).
  private static let boundaryWindow = 64

  /// The renderable prefix of a streaming tail: everything before the trailing
  /// (possibly partial) word. Boundaries come from locale-aware `.byWords`
  /// segmentation, so CJK commits at word granularity instead of stalling
  /// until a whitespace that never comes.
  static func committedPrefix(of text: String) -> Substring {
    guard let last = text.last, !last.isWhitespace else { return text[...] }

    let windowStart =
      text.index(text.endIndex, offsetBy: -boundaryWindow, limitedBy: text.startIndex)
      ?? text.startIndex
    var lastWord: Range<String.Index>?
    text.enumerateSubstrings(
      in: windowStart..<text.endIndex,
      options: [.byWords, .localized, .substringNotRequired]
    ) { _, range, _, _ in
      lastWord = range
    }

    // No word in the window (a long run of punctuation/symbols): just commit.
    guard let lastWord else { return text[...] }

    // Only a trailing WORD is held back (it may still be growing and would
    // line-jump if it wraps). Trailing punctuation commits immediately —
    // sentence-final periods land right where models pause, so holding them
    // reads as a missing period; growth just appends, and dangling markdown
    // markers ("**", "`") are hidden by the tail-tolerant parse, not by the
    // holdback.
    guard lastWord.upperBound == text.endIndex else { return text[...] }
    if text[lastWord.lowerBound...].count > holdbackCap { return text[...] }
    return text[..<lastWord.lowerBound]
  }
}

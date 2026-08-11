import SwiftUI
import UIKit

// MARK: - Non-wrapping code text view

/// The code body of a `CodeBlock`: ONE non-editable UITextView for the whole
/// block — streaming and settled — hosted inside the block's horizontal
/// ScrollView. Lines never wrap (the container is unbounded); long lines
/// extend and the ScrollView pans. The streaming word reveal is the shared
/// `WordFadeEngine`, so code tokens fade in with the same wave as prose, and
/// the whole block is natively selectable once settled.
final class CodeStreamingTextView: UITextView {
  private let fade = WordFadeEngine()
  private var cachedSize: CGSize?

  /// Inputs of the last render — same input-level dedupe as
  /// `SelectableTextView.renderedInputs`: skipping the rebuild keeps an
  /// unrelated SwiftUI update from re-assigning `attributedText`, which
  /// drops an in-flight selection.
  var renderedInputs: CodeStreamingText.RenderInputs?

  init() {
    super.init(frame: .zero, textContainer: nil)
    isEditable = false
    isSelectable = true
    isScrollEnabled = false
    backgroundColor = .clear
    textContainerInset = .zero
    textContainer.lineFragmentPadding = 0
    layoutManager.usesFontLeading = false
    // No wrapping: lines lay out at their natural width and the enclosing
    // horizontal ScrollView pans.
    textContainer.widthTracksTextView = false
    textContainer.size = CGSize(
      width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textContainer.lineBreakMode = .byClipping
    textDragInteraction?.isEnabled = false
    setContentHuggingPriority(.defaultHigh, for: .vertical)
    setContentCompressionResistancePriority(.defaultHigh, for: .vertical)
    fade.textView = self
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  override func willMove(toWindow newWindow: UIWindow?) {
    super.willMove(toWindow: newWindow)
    if newWindow == nil {
      selectedTextRange = nil
      fade.settleInstantly()
    }
  }

  func setContents(_ attributed: NSAttributedString, animated: Bool) {
    guard fade.setContents(attributed, animated: animated) else { return }
    cachedSize = nil
    invalidateIntrinsicContentSize()
  }

  /// Same-value writes are dropped: re-assigning `isSelectable` resets an
  /// active selection.
  var selectionEnabled: Bool = true {
    didSet {
      guard selectionEnabled != oldValue else { return }
      isSelectable = selectionEnabled
    }
  }

  /// Natural (unwrapped) size, cached per content version, rounded up on the
  /// pixel grid in both dimensions.
  func idealSize() -> CGSize {
    if let cachedSize { return cachedSize }
    let fitted = sizeThatFits(
      CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
    let scale = max(1, traitCollection.displayScale)
    let size = CGSize(
      width: (fitted.width * scale).rounded(.up) / scale,
      height: (fitted.height * scale).rounded(.up) / scale)
    cachedSize = size
    return size
  }
}

// MARK: - Representable

/// Streams a code block's text with the word-fade reveal and native
/// selection. Plain monospaced text renders immediately; highlight.js colors
/// land later as an attribute-only update, which the fade engine applies
/// without disturbing in-flight reveals (fading tokens continue fading into
/// their syntax colors).
struct CodeStreamingText: UIViewRepresentable {
  let code: String
  /// Highlighted lines from `CodeBlockHighlightModel`, aligned with `code`'s
  /// lines. A line's colors apply only while its text still matches the live
  /// code — during streaming the highlight lags by a throttle interval, and a
  /// stale line must render plain rather than show old colors.
  var highlightedLines: [AttributedString]?
  var isStreaming: Bool = false
  var fontSize: CGFloat = 13
  var lineSpacing: CGFloat = 5

  func makeUIView(context: Context) -> CodeStreamingTextView {
    CodeStreamingTextView()
  }

  /// Everything that feeds the attributed-code build; unchanged inputs skip
  /// the render (see `CodeStreamingTextView.renderedInputs`).
  struct RenderInputs: Equatable {
    let code: String
    let highlightedLines: [AttributedString]?
    let isStreaming: Bool
    let fontSize: CGFloat
    let lineSpacing: CGFloat
  }

  func updateUIView(_ view: CodeStreamingTextView, context: Context) {
    view.selectionEnabled = !isStreaming
    let inputs = RenderInputs(
      code: code, highlightedLines: highlightedLines, isStreaming: isStreaming,
      fontSize: fontSize, lineSpacing: lineSpacing)
    guard view.renderedInputs != inputs else { return }
    view.renderedInputs = inputs
    view.setContents(attributedCode(), animated: isStreaming)
  }

  func sizeThatFits(
    _ proposal: ProposedViewSize, uiView: CodeStreamingTextView, context: Context
  ) -> CGSize? {
    uiView.idealSize()
  }

  // MARK: Attribute assembly

  private func attributedCode() -> NSAttributedString {
    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.lineSpacing = lineSpacing
    paragraphStyle.lineBreakStrategy = []

    let result = NSMutableAttributedString(
      string: code,
      attributes: [
        .font: UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
        .foregroundColor: UIColor.label,
        .paragraphStyle: paragraphStyle,
      ])

    guard let highlightedLines else { return result }
    let nsCode = code as NSString
    var offset = 0
    for (index, plain) in code.components(separatedBy: .newlines).enumerated() {
      let length = (plain as NSString).length
      defer { offset += length + 1 }  // +1 for the newline
      guard !plain.isEmpty, highlightedLines.indices.contains(index) else { continue }
      let highlighted = highlightedLines[index]

      // The highlight is produced from an earlier snapshot of this line, so
      // while streaming it lags the live text by a throttle interval. Color the
      // longest prefix that still matches char-for-char rather than demanding
      // the whole line match: a line whose tail is mid-stream keeps its settled
      // head colored instead of dropping to plain — which, alpha-scaled by the
      // word fade, is what reads as a dim gray block until the highlight catches
      // up. The matched prefix is identical text, so UTF-16 offsets align 1:1
      // between the highlighted line and `plain`.
      let matchLen = Self.commonPrefixUTF16Length(plain, String(highlighted.characters))
      guard matchLen > 0 else { continue }

      let line = NSAttributedString(highlighted)
      line.enumerateAttribute(
        .foregroundColor, in: NSRange(location: 0, length: line.length)
      ) { value, sub, _ in
        guard let color = value as? UIColor else { return }
        let end = min(sub.upperBound, matchLen)
        guard end > sub.location else { return }
        let target = NSRange(location: offset + sub.location, length: end - sub.location)
        guard target.upperBound <= nsCode.length else { return }
        result.addAttribute(.foregroundColor, value: color, range: target)
      }
    }
    return result
  }

  /// UTF-16 length of the longest shared grapheme prefix of `a` and `b` — the
  /// span a lagging highlight can still color correctly. Walks graphemes (not
  /// UTF-16 units) so a split surrogate pair never lands mid-prefix.
  private static func commonPrefixUTF16Length(_ a: String, _ b: String) -> Int {
    var len = 0
    var ai = a.startIndex
    var bi = b.startIndex
    while ai < a.endIndex, bi < b.endIndex, a[ai] == b[bi] {
      len += a[ai].utf16.count
      ai = a.index(after: ai)
      bi = b.index(after: bi)
    }
    return len
  }
}

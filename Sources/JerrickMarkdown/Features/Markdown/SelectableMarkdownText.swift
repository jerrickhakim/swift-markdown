import SwiftUI
import UIKit

// MARK: - UIKit attribute conversion

extension InlineMarkdown {
  /// UIKit-flavored rendering of the inline parse. SwiftUI `AttributedString`
  /// font/color attributes don't bridge to NSAttributedString, so trait runs
  /// map straight to UIFont/UIColor here.
  static func nsAttributedString(
    _ markdown: String, style: Style, lineSpacing: CGFloat,
    isTail: Bool = false, alignment: MarkdownAlignment = .leading
  ) -> NSAttributedString {
    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.lineSpacing = lineSpacing
    switch alignment {
    case .leading: paragraphStyle.alignment = .natural
    case .center: paragraphStyle.alignment = .center
    case .trailing: paragraphStyle.alignment = .right
    }
    // Greedy line breaking, matching SwiftUI Text. UITextView defaults to
    // `.standard`, which packs lines differently (CJK-aware push-out) and
    // can reflow a word to a different line between commits.
    paragraphStyle.lineBreakStrategy = []

    let result = NSMutableAttributedString()
    for run in traitRuns(markdown, isTail: isTail) {
      // `<kbd>` shares the monospaced treatment of inline code.
      let mono = run.code || run.kbd
      var attributes: [NSAttributedString.Key: Any] = [
        .paragraphStyle: paragraphStyle,
        .font: uiFont(for: run, style: style),
        .foregroundColor: UIColor(
          run.isLink
            ? style.linkColor
            : (mono ? (style.codeColor ?? style.textColor) : style.textColor)
        ),
      ]
      // Background fills (code chip, kbd key, mark highlight). The word-fade
      // engine fades `.backgroundColor` with the text, so these breathe in
      // rather than popping under invisible glyphs.
      if run.kbd {
        attributes[.backgroundColor] = UIColor(style.kbdBackground)
      } else if run.code, let background = style.codeBackground {
        attributes[.backgroundColor] = UIColor(background)
      }
      if run.mark {
        attributes[.backgroundColor] = UIColor(style.markHighlight)
      }
      // Baseline shifts for <sup>/<sub>. Static attribute — the per-frame fade
      // only rewrites colors, so the offset persists through the reveal.
      if run.superscript {
        attributes[.baselineOffset] = style.fontSize * 0.35
      } else if run.subscriptt {
        attributes[.baselineOffset] = -style.fontSize * 0.18
      }
      if run.underline {
        attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
      }
      if run.strikethrough {
        attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
      }
      if run.isLink, let destination = run.linkDestination, let url = URL(string: destination) {
        attributes[.link] = url
      }
      result.append(NSAttributedString(string: run.text, attributes: attributes))
    }
    return result
  }

  private static func uiFont(for run: TraitRun, style: Style) -> UIFont {
    let weight = uiWeight(run.bold ? style.strongWeight : style.baseWeight)
    // <sup>/<sub> render at 75% size; <kbd> shares inline code's mono scale.
    let scriptScale: CGFloat = (run.superscript || run.subscriptt) ? 0.75 : 1
    let mono = run.code || run.kbd
    let size = style.fontSize * (mono ? style.codeScale : 1) * scriptScale
    var font: UIFont =
      mono
      ? .monospacedSystemFont(ofSize: size, weight: weight)
      : .systemFont(ofSize: size, weight: weight)
    if !mono, run.italic || style.italic {
      let traits = font.fontDescriptor.symbolicTraits.union(.traitItalic)
      if let descriptor = font.fontDescriptor.withSymbolicTraits(traits) {
        font = UIFont(descriptor: descriptor, size: font.pointSize)
      }
    }
    return font
  }

  private static func uiWeight(_ weight: Font.Weight) -> UIFont.Weight {
    switch weight {
    case .bold: return .bold
    case .semibold: return .semibold
    case .medium: return .medium
    case .light: return .light
    case .heavy: return .heavy
    default: return .regular
    }
  }
}

// MARK: - Hardened UITextView

/// Non-editable, non-scrolling UITextView used for ALL prose blocks —
/// streaming and settled — so there is never a view swap and users get REAL
/// text selection (grabber handles, partial ranges, loupe, system edit menu)
/// the moment a block settles. The streaming word reveal is driven by the
/// shared `WordFadeEngine` (display-only color animation, no re-layout).
final class SelectableTextView: UITextView {
  var onLinkTap: ((URL) -> Void)?

  /// Inputs of the last render, for input-level deduping in `updateUIView`.
  /// NSAttributedString equality can't do this job: `UIColor(Color)` produces
  /// provider-backed dynamic colors that compare by identity, so two builds of
  /// the SAME markdown never test equal — and every unrelated SwiftUI update
  /// would re-assign `attributedText`, which drops an in-flight selection
  /// (press-and-hold deselected instantly whenever a re-render hit the row).
  var renderedInputs: SelectableMarkdownText.RenderInputs?

  private let fade = WordFadeEngine()
  private var cachedSize: CGSize?
  private var cachedWidth: CGFloat = -1

  override init(frame: CGRect, textContainer: NSTextContainer?) {
    super.init(frame: frame, textContainer: textContainer)
    isEditable = false
    isSelectable = true
    isScrollEnabled = false
    backgroundColor = .clear
    textContainerInset = .zero
    self.textContainer.lineFragmentPadding = 0
    // TextKit adds the font's internal leading above each line; drop it so
    // line metrics are plain ascent+descent + the paragraph lineSpacing.
    layoutManager.usesFontLeading = false
    self.textContainer.widthTracksTextView = true
    // Our attributes already style links; UITextView's defaults would stomp them.
    linkTextAttributes = [:]
    // Dragging from a row that a stream rebuild can tear down crashes UIKit.
    textDragInteraction?.isEnabled = false
    delegate = self
    setContentHuggingPriority(.defaultHigh, for: .vertical)
    setContentCompressionResistancePriority(.defaultHigh, for: .vertical)
    fade.textView = self
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  // "UIPreviewTarget requires that the container view is in a window": when a
  // LazyVStack reclaims the row, a pending selection menu would reference the
  // detached view. Clear selection on the way out; also stop the fade clock —
  // a reclaimed row finishes its reveal instantly if it ever comes back.
  override func willMove(toWindow newWindow: UIWindow?) {
    super.willMove(toWindow: newWindow)
    if newWindow == nil {
      selectedTextRange = nil
      fade.settleInstantly()
    }
  }

  func setContents(_ attributed: NSAttributedString, animated: Bool) {
    guard fade.setContents(attributed, animated: animated) else { return }
    cachedWidth = -1
    cachedSize = nil
    invalidateIntrinsicContentSize()
  }

  /// While streaming, selection over text whose colors are rewritten per
  /// frame would jitter; it re-enables the moment the block settles.
  /// Same-value writes are dropped: re-assigning `isSelectable` resets an
  /// active selection.
  var selectionEnabled: Bool = true {
    didSet {
      guard selectionEnabled != oldValue else { return }
      isSelectable = selectionEnabled
    }
  }

  // MARK: Measurement

  /// Width-keyed measurement cache (rounded to a decimal so floating-point
  /// jitter doesn't miss), invalidated on content change.
  func sizeFitting(width: CGFloat) -> CGSize {
    let key = (width * 10).rounded() / 10
    if key == cachedWidth, let cachedSize { return cachedSize }
    let fitted = sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    // Round up on the pixel grid, not to a whole point — sub-point height
    // inflation across many blocks reads as drift against sibling views.
    let scale = max(1, traitCollection.displayScale)
    let size = CGSize(width: width, height: (fitted.height * scale).rounded(.up) / scale)
    cachedWidth = key
    cachedSize = size
    return size
  }
}

extension SelectableTextView: UITextViewDelegate {
  func textView(
    _ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction
  ) -> UIAction? {
    if case .link(let url) = textItem.content {
      return UIAction { [weak self] _ in self?.onLinkTap?(url) }
    }
    return defaultAction
  }

  // No long-press link preview menu — links open through the app's own
  // routing (repo files / in-app browser), matching the rest of the chat.
  func textView(
    _ textView: UITextView, menuConfigurationFor textItem: UITextItem, defaultMenu: UIMenu
  ) -> UITextItem.MenuConfiguration? {
    nil
  }
}

// MARK: - Representable

/// The ONE prose block view, streaming or settled. Native UIKit text
/// selection; links route through the SwiftUI `openURL` environment, so the
/// chat's existing repo-file / in-app-browser handling
/// (`MarkdownBlockItemView.handleLink`) applies unchanged. While streaming,
/// the word fade animates inside the view and selection is paused.
struct SelectableMarkdownText: UIViewRepresentable {
  let markdown: String
  let style: InlineMarkdown.Style
  var lineSpacing: CGFloat = 5
  var isStreaming: Bool = false
  var alignment: MarkdownAlignment = .leading

  @Environment(\.openURL) private var openURL

  /// Everything that feeds the attributed-string build; unchanged inputs mean
  /// the render is skipped entirely (see `SelectableTextView.renderedInputs`).
  struct RenderInputs: Equatable {
    let markdown: String
    let style: InlineMarkdown.Style
    let lineSpacing: CGFloat
    let isStreaming: Bool
    let alignment: MarkdownAlignment
  }

  func makeUIView(context: Context) -> SelectableTextView {
    SelectableTextView()
  }

  func updateUIView(_ view: SelectableTextView, context: Context) {
    let open = openURL
    view.onLinkTap = { open($0) }
    view.selectionEnabled = !isStreaming
    let inputs = RenderInputs(
      markdown: markdown, style: style, lineSpacing: lineSpacing,
      isStreaming: isStreaming, alignment: alignment)
    guard view.renderedInputs != inputs else { return }
    view.renderedInputs = inputs
    let attributed = InlineMarkdown.nsAttributedString(
      markdown, style: style, lineSpacing: lineSpacing, isTail: isStreaming,
      alignment: alignment)
    view.setContents(attributed, animated: isStreaming)
  }

  func sizeThatFits(
    _ proposal: ProposedViewSize, uiView: SelectableTextView, context: Context
  ) -> CGSize? {
    guard let width = proposal.width, width > 0, width.isFinite else { return nil }
    // A streaming block whose committed text draws nothing yet (holdback,
    // dangling markers) must occupy ZERO height — UITextView would otherwise
    // reserve a full empty line, and that phantom line is what used to shift
    // the list when the parser re-typed a speculative block. Settled blocks
    // keep the system measurement.
    if isStreaming, uiView.attributedText.length == 0 {
      return CGSize(width: width, height: 0)
    }
    return uiView.sizeFitting(width: width)
  }
}

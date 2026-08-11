import SwiftUI

/// Typography and spacing configuration for the markdown renderer.
public struct MarkdownStyle: Equatable {

  // MARK: - Inline text

  /// Body font size (16 chat / 13 reasoning).
  public var baseSize: CGFloat
  public var baseWeight: Font.Weight
  public var strongWeight: Font.Weight
  public var textColor: Color
  /// Inline code: monospaced at `codeScale` × baseSize.
  public var codeScale: CGFloat
  /// nil → inline code uses `textColor` (matches the current chat theme,
  /// which styles inline code with `.foregroundColor(.primary)` and no fill).
  public var codeColor: Color?
  /// nil → no background capsule behind inline code.
  public var codeBackground: Color?
  public var linkColor: Color

  // MARK: - Blocks

  /// Heading font scale per level 1–6. Chat uses a compressed curve so `#`
  /// headings don't read as "zoomed in" inside the narrow chat column.
  public var headingScales: [CGFloat]
  /// Extra space between wrapped lines, as a fraction of `baseSize`
  /// (0.35 × 16 ≈ 5.6pt — matches `.textual.lineSpacing(.fontScaled(0.35))`).
  public var lineSpacingFactor: CGFloat
  /// Per-block container padding.
  public var blockTopPadding: CGFloat
  public var blockBottomPadding: CGFloat

  public init(
    baseSize: CGFloat,
    baseWeight: Font.Weight = .regular,
    strongWeight: Font.Weight = .semibold,
    textColor: Color,
    codeScale: CGFloat,
    codeColor: Color? = nil,
    codeBackground: Color? = nil,
    linkColor: Color,
    headingScales: [CGFloat] = [1.4, 1.25, 1.1, 1.0, 0.9, 0.85],
    lineSpacingFactor: CGFloat,
    blockTopPadding: CGFloat = 6,
    blockBottomPadding: CGFloat
  ) {
    self.baseSize = baseSize
    self.baseWeight = baseWeight
    self.strongWeight = strongWeight
    self.textColor = textColor
    self.codeScale = codeScale
    self.codeColor = codeColor
    self.codeBackground = codeBackground
    self.linkColor = linkColor
    self.headingScales = headingScales
    self.lineSpacingFactor = lineSpacingFactor
    self.blockTopPadding = blockTopPadding
    self.blockBottomPadding = blockBottomPadding
  }

  // MARK: - Presets

  /// Full-size prose: 16pt, label 96%, link #8AB4F8.
  public static let chat = MarkdownStyle(
    baseSize: 16,
    textColor: Color.primary.opacity(0.96),
    codeScale: 0.875,
    codeColor: nil,
    codeBackground: nil,
    linkColor: Color(red: 0x8A / 255, green: 0xB4 / 255, blue: 0xF8 / 255),
    lineSpacingFactor: 0.35,
    blockBottomPadding: 16
  )

  /// Compact prose: 13pt, secondary label, link #93C5FD, tighter block rhythm.
  public static let reasoning = MarkdownStyle(
    baseSize: 13,
    textColor: Color.secondary,
    codeScale: 0.9,
    codeColor: Color.primary.opacity(0.86),
    codeBackground: nil,
    linkColor: Color(red: 0x93 / 255, green: 0xC5 / 255, blue: 0xFD / 255),
    lineSpacingFactor: 0.2,
    blockBottomPadding: 12
  )

  // MARK: - Derived inline styles

  /// Inline style for body-sized prose (paragraphs, list items, quotes).
  var inline: InlineMarkdown.Style {
    InlineMarkdown.Style(
      fontSize: baseSize,
      baseWeight: baseWeight,
      strongWeight: strongWeight,
      textColor: textColor,
      codeScale: codeScale,
      codeColor: codeColor,
      codeBackground: codeBackground,
      linkColor: linkColor
    )
  }

  /// Inline style for a heading at `level` (1–6): scaled size, heavier weight.
  func headingInline(level: Int) -> InlineMarkdown.Style {
    let clamped = min(max(level, 1), 6)
    var style = inline
    style.fontSize = (baseSize * headingScales[clamped - 1]).rounded()
    style.baseWeight = clamped <= 2 ? .bold : .semibold
    style.strongWeight = clamped <= 2 ? .bold : .semibold
    return style
  }

  /// Inline style for block quotes: secondary and italic (carried in the
  /// style so the UIKit-backed selectable path renders it too).
  var blockQuoteInline: InlineMarkdown.Style {
    var style = inline
    style.textColor = Color.secondary
    style.italic = true
    return style
  }

  public var lineSpacing: CGFloat { (baseSize * lineSpacingFactor).rounded() }
}

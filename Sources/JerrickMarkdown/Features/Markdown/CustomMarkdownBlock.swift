import SwiftUI
import SwiftUIMath

// MARK: - Custom Markdown Block

/// Prose blocks render through `StreamingMarkdownText` (tolerant inline parse,
/// selection, links, tail fade). Code blocks reuse the existing CustomMarkdown
/// `CodeBlock`. Tables get a native `Grid`.
public struct CustomMarkdownBlock: View {
  public let block: MarkdownBlockContent
  public var style: MarkdownStyle
  public var theme: MarkdownTheme
  public var isStreamingTail: Bool

  public init(
    block: MarkdownBlockContent,
    style: MarkdownStyle = .chat,
    theme: MarkdownTheme = .standard,
    isStreamingTail: Bool = false
  ) {
    self.block = block
    self.style = style
    self.theme = theme
    self.isStreamingTail = isStreamingTail
  }

  @Environment(\.colorScheme) private var colorScheme

  public var body: some View {
    let flattened = isEmptyStreamingTail
    blockView
      .padding(.top, flattened ? 0 : padding.top)
      .padding(.bottom, flattened ? 0 : padding.bottom)
  }

  @ViewBuilder
  private var blockView: some View {
    // Tables render from this ONE structural slot for both the tail-mode
    // promotion (still a .paragraph to the block parser) and the real .table
    // block, so the promotion → parsed-table handoff keeps the same view
    // identity and the per-cell reveal state inside MarkdownTable survives
    // the delimiter row arriving.
    if let table = tableContent {
      MarkdownTable(
        header: table.header, rows: table.rows, style: style,
        theme: theme,
        isStreamingTail: isStreamingTail)
    } else {
      nonTableView
    }
  }

  /// Header/rows when this block should render as a table: a parsed `.table`
  /// block, or — while streaming — a paragraph promoted by
  /// `StreamingTablePromotion` (a streaming table has no delimiter row yet,
  /// so the block parser still calls it a paragraph; promoting immediately
  /// avoids flashing literal pipes that later snap into a table).
  private var tableContent: (header: [String], rows: [[String]])? {
    switch block {
    case .table(let header, let rows):
      return (header, rows)
    case .paragraph(let text, _) where isStreamingTail:
      return StreamingTablePromotion.parse(text)
    default:
      return nil
    }
  }

  @ViewBuilder
  private var nonTableView: some View {
    switch block {
    case .paragraph(let text, let alignment):
      StreamingMarkdownText(
        markdown: text,
        style: style.inline,
        isStreamingTail: isStreamingTail,
        lineSpacing: style.lineSpacing,
        alignment: alignment
      )

    case .heading(let level, let text, let alignment):
      StreamingMarkdownText(
        markdown: text,
        style: style.headingInline(level: level),
        isStreamingTail: isStreamingTail,
        lineSpacing: style.lineSpacing,
        alignment: alignment
      )

    case .codeBlock(let language, let code):
      // Never run the blur reveal in chat: it's designed for a complete block
      // appearing at once — on a still-growing block the streamed lines mutate
      // under the mid-flight blur and read as a smeary morph. New lines get a
      // plain per-line fade inside CodeBlock instead.
      CodeBlock(
        code: code, language: language, animated: false, isStreaming: isStreamingTail,
        theme: theme)

    case .blockQuote(let text):
      MarkdownBlockQuote(
        text: text, style: style, theme: theme, isStreamingTail: isStreamingTail)

    case .list(let items):
      MarkdownList(items: items, style: style, isStreamingTail: isStreamingTail)

    case .details(let summary, let open, let blocks):
      MarkdownDetails(
        summary: summary, open: open, blocks: blocks, style: style,
        theme: theme,
        isStreamingTail: isStreamingTail)

    case .math(let latex, let complete):
      // Always the same view instance across the incomplete→complete transition
      // so MarkdownMathBlock can animate on that transition. While incomplete it
      // draws nothing (and `isEmptyStreamingTail` flattens its padding), so the
      // block has zero height until the closing `$$` arrives.
      MarkdownMathBlock(latex: latex, complete: complete, style: style)

    case .thematicBreak:
      Rectangle()
        .fill(theme.separator.resolve(for: colorScheme))
        .frame(height: 1)
        .streamingChromeFade(isStreamingTail)

    case .table:
      // Unreachable: every .table block is captured by `tableContent` and
      // rendered in the table slot above.
      EmptyView()
    }
  }

  /// True while this block is the streaming tail and its committed text draws
  /// no glyphs yet (held-back partial word, a bare "3" that will merge into
  /// the preceding list, a "-"/"--" that will become a thematic break, an
  /// opening "`"/"```" run). Such blocks render at ZERO height — padding
  /// suppressed here, text measured at 0 in `SelectableMarkdownText` — so the
  /// block parser's speculative re-typing only ever inserts/removes flat
  /// rows. Blocks are born invisible AND flat; first committed words bring
  /// the padding back as plain additive growth at the tail.
  private var isEmptyStreamingTail: Bool {
    guard isStreamingTail else { return false }
    switch block {
    case .paragraph(let text, _), .heading(_, let text, _):
      return InlineMarkdown.rendersEmpty(
        String(StreamingMarkdownText.committedPrefix(of: text)))
    case .blockQuote(let text):
      return InlineMarkdown.rendersEmpty(
        String(StreamingMarkdownText.committedPrefix(of: text)))
    case .math(let latex, let complete):
      // A math fence that hasn't closed yet (or has no LaTeX) draws nothing —
      // keep it flat until the closing `$$` arrives and it pops in.
      return !complete || latex.isEmpty
    case .details(let summary, _, let blocks):
      // A just-opened <details> with no summary or body content yet draws
      // nothing — keep it flat until its first glyphs commit.
      return summary.isEmpty && blocks.isEmpty
    case .list(let items):
      // Only a brand-new list whose sole (still-open) item is held back is
      // flat — a list with any closed item shows at least a marker row.
      guard items.count == 1, let only = items.first, only.open else { return false }
      return InlineMarkdown.rendersEmpty(
        String(StreamingMarkdownText.committedPrefix(of: only.text)))
    default:
      return false
    }
  }

  /// Vertical rhythm per block type. Paragraph-level blocks match today's
  /// styled container (top 6 / bottom 16 in chat); list items run tighter so
  /// consecutive bullets read as one list.
  private var padding: (top: CGFloat, bottom: CGFloat) {
    switch block {
    case .list:
      return (2, 10)
    case .heading(let level, _, _):
      return (level <= 2 ? 10 : 8, style.blockBottomPadding * 0.6)
    case .thematicBreak:
      return (2, 6)
    default:
      return (style.blockTopPadding, style.blockBottomPadding)
    }
  }

}

// MARK: - Math Block

/// A `$$ … $$` display-math block rendered with SwiftUIMath's pure-SwiftUI `Math`
/// view (a `Canvas`, so it scales crisply and takes `.foregroundStyle`). Wide
/// expressions (matrices, long integrals) scroll horizontally rather than clip
/// in the narrow chat column.
private struct MarkdownMathBlock: View {
  let latex: String
  let complete: Bool
  var style: MarkdownStyle = .chat

  /// Drives the whole-block fade (blur + float + opacity). Seeded from `complete`
  /// at init: a block born complete (history / settled scrollback) starts
  /// revealed and renders with no motion. A block born incomplete (live stream)
  /// starts hidden; when the closing `$$` arrives, `complete` flips and `onChange`
  /// fades the finished equation in as one unit. Keying off the transition — not
  /// appearance — is what makes the reveal survive being sealed as a non-tail
  /// block mid-stream.
  @State private var revealed: Bool

  init(latex: String, complete: Bool, style: MarkdownStyle = .chat) {
    self.latex = latex
    self.complete = complete
    self.style = style
    _revealed = State(initialValue: complete)
  }

  var body: some View {
    Group {
      if complete, !latex.isEmpty {
        ScrollView(.horizontal, showsIndicators: false) {
          Math(latex)
            .mathTypesettingStyle(.display)
            .mathFont(Math.Font(name: .latinModern, size: style.baseSize * 1.15))
            .foregroundStyle(style.textColor)
            .padding(.vertical, 2)
            .padding(.horizontal, 2)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .opacity(revealed ? 1 : 0)
        .blur(radius: revealed ? 0 : MarkdownReveal.blurRadius)
        .offset(y: revealed ? 0 : MarkdownReveal.yOffset)
      }
    }
    .onChange(of: complete) { _, nowComplete in
      guard nowComplete else { return }
      withAnimation(MarkdownReveal.spring) { revealed = true }
    }
  }
}

// MARK: - Block Quote

private struct MarkdownBlockQuote: View {
  let text: String
  let style: MarkdownStyle
  let theme: MarkdownTheme
  let isStreamingTail: Bool

  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    HStack(alignment: .top, spacing: 0) {
      RoundedRectangle(cornerRadius: 2)
        .fill(theme.separator.resolve(for: colorScheme))
        .frame(width: 4)
        .streamingChromeFade(isStreamingTail)

      StreamingMarkdownText(
        markdown: text,
        style: style.blockQuoteInline,
        isStreamingTail: isStreamingTail,
        lineSpacing: style.lineSpacing
      )
      .padding(.leading, 14)
      .padding(.vertical, 2)
    }
  }
}

// MARK: - List

/// Renders a whole `.list` block as ONE view. The list shares a single
/// StableBlock, so while it streams the tail flag stays on this block and the
/// rows keep their identity as items append — only the LAST item is still
/// growing, so only it gets `isStreamingTail`; earlier rows settle in place
/// (same view, no identity flip) and their word fades drain undisturbed.
private struct MarkdownList: View {
  let items: [MarkdownListItemData]
  let style: MarkdownStyle
  let isStreamingTail: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      ForEach(items.indices, id: \.self) { i in
        let item = items[i]
        // Only the OPEN item (parsed from the source's last line) is still
        // growing — closed items have final text, so they render in full
        // even while the block is the tail (holding their last word back
        // would hide it forever, since their text never grows again).
        let growing = isStreamingTail && item.open && i == items.count - 1
        // A just-arrived growing item whose text is still held back ("3."
        // with no words yet) renders NOTHING — not a bare marker row. The
        // row appears whole with its first committed word (additive growth),
        // and if the item turns out to be something else (a "-" that becomes
        // a thematic break), nothing was on screen to shift away.
        if !(growing
          && InlineMarkdown.rendersEmpty(
            String(StreamingMarkdownText.committedPrefix(of: item.text))))
        {
          MarkdownListItem(
            marker: item.ordered ? "\(item.index)." : Self.bulletMarker(depth: item.depth),
            depth: item.depth,
            text: item.text,
            style: style,
            isStreamingTail: growing,
            markerStreaming: isStreamingTail
          )
        }
      }
    }
  }

  private static func bulletMarker(depth: Int) -> String {
    switch depth {
    case 0: return "•"
    case 1: return "◦"
    default: return "▪"
    }
  }
}

// MARK: - List Item

private struct MarkdownListItem: View {
  let marker: String
  let depth: Int
  let text: String
  let style: MarkdownStyle
  let isStreamingTail: Bool
  /// Marker chrome fades for any row that appears while the BLOCK is
  /// streaming — `isStreamingTail` only covers the last (growing) row, but a
  /// multi-item flush lands complete middle rows that should fade in too.
  var markerStreaming: Bool = false

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(marker)
        .font(.system(size: style.baseSize, weight: style.baseWeight))
        .foregroundStyle(style.textColor)
        .frame(minWidth: 18, alignment: .trailing)
        .streamingChromeFade(markerStreaming || isStreamingTail)

      StreamingMarkdownText(
        markdown: text,
        style: style.inline,
        isStreamingTail: isStreamingTail,
        lineSpacing: style.lineSpacing
      )
    }
    .padding(.leading, CGFloat(max(0, depth)) * 20)
  }
}

// MARK: - Streaming Table Promotion

/// Detects a table that is still streaming in (header row present, delimiter
/// row absent or partial) inside what the block parser still considers a
/// paragraph, and extracts header/rows so the tail can render real table
/// chrome immediately. Mirrors SwiftStreamingMarkdown's PartialTableScanner.
enum StreamingTablePromotion {

  static func parse(_ text: String) -> (header: [String], rows: [[String]])? {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard !lines.isEmpty else { return nil }

    var header: [String]?
    var rows: [[String]] = []

    for line in lines {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.isEmpty { continue }
      // Every line must read as a pipe row, or this isn't a streaming table.
      guard trimmed.hasPrefix("|") else { return nil }
      // A (possibly partial) delimiter row — `| :--` — renders as nothing;
      // once it completes, the block parser produces a real .table block.
      if isDelimiterLike(trimmed) { continue }
      let cells = parseCells(trimmed)
      if header == nil { header = cells } else { rows.append(cells) }
    }

    guard let header, !header.isEmpty, header != [""] else { return nil }
    return (header, rows)
  }

  /// True for rows composed entirely of pipes, dashes, colons, and spaces
  /// with at least one dash/colon — i.e. a complete or partial GFM delimiter.
  private static func isDelimiterLike(_ trimmed: String) -> Bool {
    guard trimmed.contains("-") || trimmed.contains(":") else { return false }
    return trimmed.allSatisfy { "|-: \t".contains($0) }
  }

  private static func parseCells(_ trimmed: String) -> [String] {
    var raw = trimmed
    if raw.hasPrefix("|") { raw = String(raw.dropFirst()) }
    if raw.hasSuffix("|") { raw = String(raw.dropLast()) }
    return raw.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
  }
}

// MARK: - Table

/// Native `Grid` table with a rounded container,
/// tinted header row, alternating row fills, no grid lines.
///
/// While the table is the streaming tail, cells reveal with a staggered fade:
/// every growth (a new row arriving, the promotion landing the whole header
/// at once) fades its new cells in row-major order, each one `cellStagger`
/// after the previous — the table equivalent of the prose word wave. The last
/// present cell is held back while it's still growing (its closing pipe
/// hasn't arrived), mirroring the prose word holdback, and releases with a
/// fade when the next cell starts or the stream ends. Tables born settled
/// (history/scrollback) render fully visible and never animate.
private struct MarkdownTable: View {
  let header: [String]
  let rows: [[String]]
  let style: MarkdownStyle
  let theme: MarkdownTheme
  let isStreamingTail: Bool

  @Environment(\.colorScheme) private var colorScheme

  @State private var availableWidth: CGFloat = 0

  /// True if this table was born streaming; settled tables skip all cell
  /// reveal tracking and render at full strength immediately.
  @State private var hasStreamed: Bool
  /// Cells whose reveal has been scheduled, keyed `row * cellKeyStride + col`
  /// (header = row 0).
  @State private var revealedCells: Set<Int> = []
  /// Per-cell fade delay, assigned in row-major order within each growth
  /// batch so cells cascade left→right, top→bottom.
  @State private var cellDelays: [Int: Double] = [:]

  private static let cornerRadius: CGFloat = 12
  /// Gap between consecutive cell reveals within one growth batch.
  private static let cellStagger: Double = 0.07
  private static let cellKeyStride = 1024

  init(
    header: [String], rows: [[String]], style: MarkdownStyle,
    theme: MarkdownTheme = .standard, isStreamingTail: Bool = false
  ) {
    self.header = header
    self.rows = rows
    self.style = style
    self.theme = theme
    self.isStreamingTail = isStreamingTail
    _hasStreamed = State(initialValue: isStreamingTail)
  }

  private var columnCount: Int {
    max(header.count, rows.map(\.count).max() ?? 0)
  }

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
        GridRow {
          ForEach(0..<columnCount, id: \.self) { col in
            cell(
              text: header.indices.contains(col) ? header[col] : "",
              row: 0, col: col)
          }
        }

        ForEach(rows.indices, id: \.self) { rowIndex in
          GridRow {
            ForEach(0..<columnCount, id: \.self) { col in
              cell(
                text: rows[rowIndex].indices.contains(col) ? rows[rowIndex][col] : "",
                row: rowIndex + 1, col: col
              )
            }
          }
        }
      }
      // Stretch a narrow table to the scroll container's width so header and
      // row fills span the full available content width. Wide tables keep
      // their ideal width and scroll horizontally as before.
      .frame(minWidth: availableWidth > 0 ? availableWidth : nil, alignment: .leading)
    }
    .onGeometryChange(for: CGFloat.self) { proxy in
      proxy.size.width
    } action: { width in
      availableWidth = width
    }
    // Selection is owned here (not by a chat-level ancestor) so the
    // streaming tail stays free of .textSelection, which would kill the
    // prose word-fade TextRenderer. Table cells never use one.
    .textSelection(.enabled)
    .background(containerBackground)
    .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
    // The container chrome fades in with the first cells instead of popping
    // as an empty rounded slab.
    .streamingChromeFade(isStreamingTail)
    .onChange(of: revealSignature, initial: true) {
      revealNewlyReadyCells()
    }
  }

  private func cell(text: String, row: Int, col: Int) -> some View {
    var inline = style.inline
    if row == 0 {
      inline.baseWeight = .semibold
      inline.textColor = theme.table.headerText.resolve(for: colorScheme)
    } else {
      inline.textColor = theme.table.bodyText.resolve(for: colorScheme)
    }
    let key = cellKey(row, col)
    let revealed = isRevealed(key)
    // Row fills live on the cell (a GridRow background paints each cell view
    // individually anyway) so each cell's tint fades in with its text. The
    // cell must fill its grid cell or the fill only hugs the text.
    return Text(InlineMarkdown.attributedString(text, style: inline))
      .lineSpacing(style.baseSize * 0.25)
      .frame(minWidth: 80, maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
      .padding(.vertical, 10)
      .padding(.horizontal, 14)
      .background(rowFill(row))
      .opacity(revealed ? 1 : 0)
      .animation(
        .easeOut(duration: MarkdownReveal.streamFadeDuration)
          .delay(cellDelays[key] ?? 0),
        value: revealed
      )
  }

  // MARK: Cell reveal

  private func cellKey(_ row: Int, _ col: Int) -> Int {
    row * Self.cellKeyStride + col
  }

  private func isRevealed(_ key: Int) -> Bool {
    !hasStreamed || revealedCells.contains(key)
  }

  /// Readiness driver: a new row, a new cell in the last row, a new column,
  /// or the stream ending all change this and trigger a reveal pass.
  private var revealSignature: [Int] {
    [isStreamingTail ? 1 : 0, columnCount, header.count] + rows.map(\.count)
  }

  /// Row-major keys of cells whose content is final enough to reveal. While
  /// the table is the streaming tail, the last present cell is still growing
  /// (its terminating pipe hasn't arrived) and is held back along with the
  /// not-yet-present cells after it.
  private var readyCellKeys: [Int] {
    let cellRows = [header] + rows
    let lastRow = cellRows.count - 1
    var keys: [Int] = []
    for row in 0...lastRow {
      for col in 0..<columnCount {
        if isStreamingTail, row == lastRow, col >= cellRows[row].count - 1 { continue }
        keys.append(cellKey(row, col))
      }
    }
    return keys
  }

  /// Schedules a staggered fade for every newly-ready cell. Each growth is
  /// its own batch: delays restart at 0, so a single new cell fades on
  /// arrival and a whole flushed row sweeps across. Capped so a giant dump
  /// finishes in bounded time.
  private func revealNewlyReadyCells() {
    guard hasStreamed else { return }
    let fresh = readyCellKeys.filter { !revealedCells.contains($0) }
    guard !fresh.isEmpty else { return }
    for (index, key) in fresh.enumerated() {
      cellDelays[key] = min(Double(index) * Self.cellStagger, MarkdownReveal.maxStagger)
    }
    revealedCells.formUnion(fresh)
  }

  /// Header tint for row 0, alternating tint for every other data row
  /// (header counts as row 0, matching the table theme's
  /// "row > 0 && row.isMultiple(of: 2)").
  private func rowFill(_ row: Int) -> Color {
    if row == 0 { return headerBackground }
    return row.isMultiple(of: 2) ? alternateRowBackground : Color.clear
  }

  // MARK: Colors

  private var containerBackground: Color {
    theme.table.containerBackground.resolve(for: colorScheme)
  }

  private var headerBackground: Color {
    theme.table.headerBackground.resolve(for: colorScheme)
  }

  private var alternateRowBackground: Color {
    theme.table.alternateRowBackground.resolve(for: colorScheme)
  }
}

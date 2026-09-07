import Foundation
import Observation

// MARK: - Parsed Markdown Block

/// One item within a `.list` block.
public struct MarkdownListItemData: Equatable, Sendable {
    public var depth: Int
    public var ordered: Bool
    /// Ordinal for ordered items ("3." → 3); unused for unordered.
    public var index: Int
    public var text: String
    /// True when this item came from the LAST line of the parsed source — its
    /// text may still be growing. Only an open item gets the streaming word
    /// holdback; a closed item's text is final (more source lines follow it),
    /// so holding its last word back would hide it forever.
    public var open: Bool = false

    public init(depth: Int, ordered: Bool, index: Int, text: String, open: Bool = false) {
        self.depth = depth
        self.ordered = ordered
        self.index = index
        self.text = text
        self.open = open
    }
}

/// Horizontal alignment for a block. Markdown blocks are always `.leading`;
/// HTML `<p align>` / `<h3 align>` can request center/right.
public enum MarkdownAlignment: Equatable, Sendable {
    case leading, center, trailing
}

/// The raw block content produced by parsing. Value type — no identity.
public enum MarkdownBlockContent: Equatable, Sendable {
    case heading(level: Int, text: String, alignment: MarkdownAlignment)
    case paragraph(text: String, alignment: MarkdownAlignment)
    case codeBlock(language: String?, code: String)
    case blockQuote(text: String)
    /// A contiguous run of list items (ordered/unordered/mixed depths) parsed
    /// as ONE block. Item-per-block parsing made every list line its own
    /// StableBlock, so the streaming-tail flag hopped blocks on each new item
    /// and the word fade was torn down per line. One shared block keeps the
    /// whole list as the tail while it grows.
    case list(items: [MarkdownListItemData])
    case thematicBreak
    /// A `$$ … $$` display-math block (LaTeX), rendered via SwiftUIMath. `complete`
    /// is false while the closing `$$` fence hasn't arrived yet — a still-streaming
    /// block renders at zero height (like incomplete HTML) instead of flashing
    /// broken LaTeX, then pops in once the fence closes.
    case math(latex: String, complete: Bool)
    case table(header: [String], rows: [[String]])
    /// An HTML `<details>` collapsible: a summary (parsed as blocks so a code
    /// block or inline markup inside `<summary>` renders) plus the body blocks
    /// it reveals. `open` mirrors the `<details open>` attribute. Recursive —
    /// nested `<details>` land as `.details` children.
    case details(summary: [MarkdownBlockContent], open: Bool, blocks: [MarkdownBlockContent])

    var type: String {
        switch self {
        case .heading:           return "heading"
        case .paragraph:         return "paragraph"
        case .codeBlock:         return "codeBlock"
        case .blockQuote:        return "blockQuote"
        case .list:              return "list"
        case .thematicBreak:     return "thematicBreak"
        case .math:              return "math"
        case .table:             return "table"
        case .details:           return "details"
        }
    }

}

// MARK: - Stable Block (observable reference type)

/// Each block is a reference-type object so SwiftUI tracks it individually.
/// When only one block's `content` changes, only that block's view re-renders.
@Observable
public final class StableBlock: Identifiable {
    public let id: UUID
    public private(set) var content: MarkdownBlockContent

    /// Bumps every time `content` is reassigned. Downstream reconcilers can pair
    /// this with `id` to skip deep content (AST) equality checks: a matching
    /// `(id, version)` provably means the content hasn't changed since it was
    /// last applied. Not observed — it's bookkeeping, not a render input.
    @ObservationIgnored public private(set) var version: UInt64 = 0

    public init(id: UUID = UUID(), content: MarkdownBlockContent) {
        self.id = id
        self.content = content
    }

    /// Replace the block's content and advance its version.
    func setContent(_ newContent: MarkdownBlockContent) {
        content = newContent
        version &+= 1
    }
}

// MARK: - Stable Markdown Parser

/// Incrementally parses markdown and stabilizes block identities across updates.
/// Blocks that haven't changed keep their object reference untouched.
/// Only the trailing (in-progress) block gets its `content` mutated,
/// which triggers a re-render for that single block only.
///
/// OPTIMIZATION: Instead of re-parsing the entire markdown on every token,
/// we cache the "stable prefix" — all blocks whose source lines are complete
/// (followed by a blank line or a different block type). On each update we
/// only re-parse from where the last stable block ended, keeping the cost
/// proportional to the new/trailing content, not the full response.
@Observable
public final class StableMarkdownParser {
    public private(set) var blocks: [StableBlock] = []

    /// Incremental bookkeeping — not observed, because `blocks` is the only
    /// render input; routing this state through the registrar would charge every
    /// streamed flush for observations no view ever makes.
    ///
    /// Number of blocks whose content is finalized (won't change with more text).
    @ObservationIgnored private var stableCount = 0
    /// UTF-8 byte offset in the source where the stable prefix ends — the start
    /// of the trailing (still-mutable) block. On next update we only parse from here.
    @ObservationIgnored private var stableUTF8Offset = 0
    /// The previous markdown string, used for the no-change fast path and the
    /// stable-prefix comparison.
    @ObservationIgnored private var previousMarkdown = ""
    /// The mutable tail's shape, when appended bytes can fold straight into the
    /// trailing block instead of re-parsing the run it already holds. A streaming
    /// list, quote, table, or fenced code block otherwise re-parses every line it
    /// holds on every flush — quadratic in the block's own length, which is
    /// exactly the shape a long list or code block streams in as.
    private enum TailShape {
        /// Re-parse the whole tail; nothing about it is safe to fold into.
        case unknown
        /// Raw prose retains whitespace that may become interior on the next append.
        case paragraph(source: String)
        /// Items before the unfinished source line, including across blank lines.
        case list(settledItems: Int)
        case details(bodyParser: StableMarkdownParser)
        /// One table whose rows map 1:1 onto `tailLines` past the delimiter row.
        case table
        /// An open fence. Its body is copied verbatim, so the appended bytes are
        /// exactly what the block's code gained.
        case codeFence(marker: UInt8)
        /// `settled` is the UNTRIMMED quote text of the first `settledLines`
        /// lines — the block's own text is trimmed, so it can't be appended to.
        case blockQuote(settled: String, settledLines: Int)
    }
    /// Re-established by every full tail parse; `.unknown` keeps the next update
    /// on that path.
    @ObservationIgnored private var tailShape: TailShape = .unknown
    /// The mutable tail's source lines, carried across updates. Splitting the
    /// tail was ~35% of a streamed list's parse time because a growing block
    /// re-split every line it already held on every flush; an append extends
    /// these in place instead, and sealing a block drops the lines it consumed.
    @ObservationIgnored private var tailLines: [String] = []
    /// Whether `tailLines` still describes `previousMarkdown[stableUTF8Offset...]`.
    @ObservationIgnored private var tailLinesValid = false

    /// Re-parse only the trailing portion of the markdown string.
    ///
    /// PERF: every per-update step is O(tail), not O(full text). The previous
    /// version ran `hasPrefix(previousMarkdown)`, a grapheme-walking
    /// `dropFirst(stableOffset)`, and a `components(separatedBy: "\n")` over the
    /// FULL accumulated markdown on every streamed flush — quadratic over a long
    /// response. The stable offset is now byte-based and advanced from the tail
    /// parse alone.
    public init() {}

    public func update(markdown: String) {
        update(markdown: markdown, isKnownAppend: false)
    }

    /// Chat text deltas only ever append to a part. That caller can skip the
    /// settled-prefix byte comparison; generic document/editor callers keep the
    /// defensive `update(markdown:)` path because their source may change anywhere.
    func updateAppending(markdown: String) {
        update(markdown: markdown, isKnownAppend: true)
    }

    private func update(markdown: String, isKnownAppend: Bool) {
        // Fast path: if nothing changed, skip entirely
        if markdown == previousMarkdown { return }

        // A changed String of the same/shorter length cannot be an append; fall
        // back to validation even if a caller accidentally uses the fast API.
        let utf8 = markdown.utf8
        let previousUTF8Count = previousMarkdown.utf8.count
        let isAppend = isKnownAppend && utf8.count > previousUTF8Count

        // Fold the appended bytes into the trailing block when the tail's shape
        // makes that equivalent to re-parsing it. `tailLines` is brought current
        // first because the slow path below needs it either way, so a fold that
        // bails costs nothing beyond the work that update already owed.
        var tailIsCurrent = false
        if isAppend, tailLinesValid, !tailLines.isEmpty, blocks.count == stableCount + 1,
           previousUTF8Count >= stableUTF8Offset {
            let appended = utf8[utf8.index(utf8.startIndex, offsetBy: previousUTF8Count)...]
            let openLine = tailLines.count - 1
            refreshTailLines(
                markdown: markdown, isAppend: true, previousUTF8Count: previousUTF8Count)
            tailIsCurrent = true
            if foldAppend(fromLine: openLine, appended: appended) {
                previousMarkdown = markdown
                return
            }
        }
        tailShape = .unknown

        // The stable prefix is valid when the settled bytes are untouched — then
        // only the tail re-parses. Edits AFTER the stable offset (not just
        // appends) are covered too, since the whole tail is re-parsed and
        // reconciled. Otherwise the tail is the whole document: a response that
        // is still ONE block has no stable prefix, which is the common streaming
        // shape, so both cases run the same cached-line path from offset zero.
        let prefixValid = stableCount > 0 && (isAppend || hasUnchangedStablePrefix(markdown))
        if !prefixValid {
            if stableUTF8Offset != 0 { tailLinesValid = false }
            stableCount = 0
            stableUTF8Offset = 0
        }

        if !tailIsCurrent {
            refreshTailLines(
                markdown: markdown, isAppend: isAppend, previousUTF8Count: previousUTF8Count)
        }
        let tailBlocks = MarkdownParser.parse(lines: tailLines)

        // stableUTF8Offset points to the start of block[stableCount] (the trailing
        // block), so tailBlocks[0] corresponds to that block. Reconcile from there —
        // not from stableCount - 1, which would clobber the last stable block.
        reconcileTail(tailBlocks, from: stableCount)

        // All blocks except the mutable tail are now "done". Advance the stable
        // offset by where the new trailing region starts WITHIN the tail — no
        // full-string re-scan — and drop the lines it consumed from the cache.
        let newStable = stableBlockCount()
        if newStable > stableCount, !tailBlocks.isEmpty {
            let sealed = Self.sourceLineCount(forBlocks: newStable - stableCount, in: tailLines)
            for index in 0..<sealed {
                stableUTF8Offset += tailLines[index].utf8.count + 1
            }
            tailLines.removeFirst(sealed)
            stableUTF8Offset = min(stableUTF8Offset, utf8.count)
            stableCount = newStable
        }
        tailShape = Self.tailShape(for: tailBlocks, lines: tailLines)

        previousMarkdown = markdown
    }

    /// Classifies a freshly parsed tail. Anything that isn't a single block whose
    /// content maps line-for-line onto `lines` stays `.unknown`, which keeps the
    /// next update on the full tail re-parse.
    private static func tailShape(
        for tailBlocks: [MarkdownBlockContent], lines: [String]
    ) -> TailShape {
        guard tailBlocks.count == 1, let last = lines.last else { return .unknown }
        // A blank last line means the block already closed before it, so the
        // line-to-content mapping is one short.
        let blankLast = MarkdownParser.isHorizontalWhitespaceOnly(last)
        switch tailBlocks[0] {
        case .paragraph(_, let alignment):
            guard alignment == .leading,
                  MarkdownParser.plainSingleLineParagraphText(lines[0]) != nil,
                  MarkdownParser.canAppendParagraphLines(lines, from: 0)
            else { return .unknown }
            return .paragraph(source: lines.joined(separator: "\n"))
        case .list(let items):
            let contiguous = items.count == lines.count
                || (items.count == lines.count - 1 && blankLast)
            if !contiguous {
                var sourceItems = 0
                for line in lines {
                    if MarkdownParser.parseListItemLine(line) != nil {
                        sourceItems += 1
                    } else if !MarkdownParser.isHorizontalWhitespaceOnly(line) {
                        return .unknown
                    }
                }
                guard sourceItems == items.count else { return .unknown }
            }
            return .list(settledItems: items.count - (blankLast ? 0 : 1))
        case .details:
            guard let body = MarkdownParser.detailsBodyForAppending(lines: lines) else {
                return .unknown
            }
            let parser = StableMarkdownParser()
            parser.updateAppending(markdown: body)
            guard case .paragraph = parser.tailShape else { return .unknown }
            return .details(bodyParser: parser)
        case .table(_, let rows):
            guard lines.count >= 3 else { return .unknown }
            let matches = rows.count == lines.count - 2
                || (rows.count == lines.count - 3 && blankLast)
            return matches ? .table : .unknown
        case .codeBlock:
            // `<pre>` HTML lands here too, and a fence that already closed keeps
            // its body — only an OPEN fence takes the appended bytes as code.
            guard lines.count >= 2 else { return .unknown }
            let marker: UInt8
            if MarkdownParser.hasFencePrefix(lines[0], 0x60) {
                marker = 0x60
            } else if MarkdownParser.hasFencePrefix(lines[0], 0x7E) {
                marker = 0x7E
            } else {
                return .unknown
            }
            for index in 1..<lines.count
            where MarkdownParser.hasFencePrefix(lines[index], marker) {
                return .unknown
            }
            return .codeFence(marker: marker)
        case .blockQuote:
            return .blockQuote(settled: "", settledLines: 0)
        default:
            return .unknown
        }
    }

    /// Folds appended bytes into the trailing block. `openLine` indexes the tail
    /// line that was still growing before the append — every line before it is
    /// settled. Returns false when the appended text changes the block's grammar
    /// (a fence closes, an item turns into a rule, a row loses its pipes) and the
    /// whole tail has to re-parse.
    private func foldAppend(fromLine openLine: Int, appended: String.UTF8View.SubSequence) -> Bool {
        switch tailShape {
        case .unknown:
            return false
        case .paragraph(let source):
            return foldParagraph(source: source, fromLine: openLine, appended: appended)
        case .list(let settledItems):
            return foldListItems(fromLine: openLine, settledItems: settledItems)
        case .details(let bodyParser):
            return foldDetails(bodyParser: bodyParser, appended: appended)
        case .table:
            return foldTableRows(fromLine: openLine)
        case .codeFence(let marker):
            return foldCodeFence(fromLine: openLine, marker: marker, appended: appended)
        case .blockQuote(let settled, let settledLines):
            return foldBlockQuote(settled: settled, settledLines: settledLines)
        }
    }

    private func foldParagraph(
        source: String, fromLine openLine: Int, appended: String.UTF8View.SubSequence
    ) -> Bool {
        guard MarkdownParser.canAppendParagraphLines(tailLines, from: openLine) else {
            return false
        }
        let updated = tailLines.count == 1
            ? tailLines[0]
            : source + String(decoding: appended, as: UTF8.self)
        tailShape = .paragraph(source: updated)
        setTailContent(.paragraph(text: MarkdownParser.trimmedIfNeeded(updated), alignment: .leading))
        return true
    }

    private func foldDetails(
        bodyParser: StableMarkdownParser, appended: String.UTF8View.SubSequence
    ) -> Bool {
        // Any HTML could close the container or change which text belongs to its summary.
        guard !MarkdownParser.containsByte(appended, 0x3C),
              case .details(let summary, let open, _) = blocks[stableCount].content
        else { return false }
        bodyParser.updateAppending(
            markdown: bodyParser.previousMarkdown + String(decoding: appended, as: UTF8.self))
        guard bodyParser.blocks.count == 1,
              case .paragraph = bodyParser.blocks[0].content,
              bodyParser.stableCount == 0
        else { return false }
        setTailContent(.details(summary: summary, open: open, blocks: [bodyParser.blocks[0].content]))
        return true
    }

    private func foldListItems(fromLine openLine: Int, settledItems: Int) -> Bool {
        guard case .list(let items) = blocks[stableCount].content,
              settledItems <= items.count else { return false }

        var updated = Array(items.prefix(settledItems))
        // A previously open item closes even when this delta contains only blank lines.
        if !updated.isEmpty { updated[updated.count - 1].open = false }
        var nextSettledItems = updated.count
        for index in openLine..<tailLines.count {
            let line = tailLines[index]
            if index == tailLines.count - 1 { nextSettledItems = updated.count }
            guard var item = MarkdownParser.parseListItemLine(line) else {
                guard MarkdownParser.isHorizontalWhitespaceOnly(line) else { return false }
                continue
            }
            if !item.ordered, MarkdownParser.startsWithThematicBreakMarker(item.text),
               MarkdownParser.isThematicBreak(line) {
                return false
            }
            item.open = index == tailLines.count - 1
            updated.append(item)
        }
        tailShape = .list(settledItems: nextSettledItems)
        // The preceding item may have closed; every item before it is unchanged.
        let changedStart = max(0, settledItems - 1)
        if updated.count != items.count
            || !updated[changedStart...].elementsEqual(items[changedStart...]) {
            blocks[stableCount].setContent(.list(items: updated))
        }
        return true
    }

    /// Rewrites the open row and appends whatever rows the delta completed.
    private func foldTableRows(fromLine openLine: Int) -> Bool {
        // The header and delimiter rows are settled before a fold can run.
        guard openLine >= 2,
              case .table(let header, let rows) = blocks[stableCount].content,
              rows.count == openLine - 2 || rows.count == openLine - 1
        else { return false }

        let settled = openLine - 2
        var updated = Array(rows[..<settled])
        updated.reserveCapacity(tailLines.count - 2)
        for index in openLine..<tailLines.count {
            let line = tailLines[index]
            guard MarkdownParser.containsByte(line.utf8, 0x7C) else {
                // A pipe-less line ends the table; only a blank one can do that
                // without opening a second block in the tail.
                guard index == tailLines.count - 1,
                      MarkdownParser.isHorizontalWhitespaceOnly(line)
                else { return false }
                break
            }
            updated.append(MarkdownParser.parseTableCells(line))
        }
        if updated.count != rows.count
            || !updated[settled...].elementsEqual(rows[settled...]) {
            blocks[stableCount].setContent(.table(header: header, rows: updated))
        }
        return true
    }

    /// A fence body is copied verbatim, so the appended bytes are exactly what
    /// the code gained — unless one of the new lines closes the fence.
    private func foldCodeFence(
        fromLine openLine: Int, marker: UInt8, appended: String.UTF8View.SubSequence
    ) -> Bool {
        // openLine == 0 is the opening fence still being typed; its bytes are the
        // language, not code.
        guard openLine >= 1,
              case .codeBlock(let language, var code) = blocks[stableCount].content
        else { return false }
        for index in openLine..<tailLines.count
        where MarkdownParser.hasFencePrefix(tailLines[index], marker) {
            return false
        }
        code += String(decoding: appended, as: UTF8.self)
        blocks[stableCount].setContent(.codeBlock(language: language, code: code))
        return true
    }

    /// Extends the quote with the lines the delta completed. The block's own text
    /// is trimmed, so the fold carries the untrimmed text of the settled lines and
    /// re-derives the open line's contribution on top of it.
    private func foldBlockQuote(settled: String, settledLines: Int) -> Bool {
        let openLine = tailLines.count - 1
        guard settledLines <= openLine else { return false }

        var text = settled
        for index in settledLines..<openLine {
            // A blank line stays inside the quote only when another quoted line
            // follows it, which the full parse resolves with a lookahead.
            guard let quoted = MarkdownParser.blockQuoteLineContent(tailLines[index]) else {
                return false
            }
            if index > 0 { text.append("\n") }
            text += quoted
        }
        tailShape = .blockQuote(settled: text, settledLines: openLine)

        if let quoted = MarkdownParser.blockQuoteLineContent(tailLines[openLine]) {
            if openLine > 0 { text.append("\n") }
            text += quoted
        } else if !MarkdownParser.isHorizontalWhitespaceOnly(tailLines[openLine]) {
            // Anything else ends the quote and opens a second block in the tail.
            return false
        }
        setTailContent(.blockQuote(text: MarkdownParser.trimmedIfNeeded(text)))
        return true
    }

    @inline(__always)
    private func setTailContent(_ content: MarkdownBlockContent) {
        if blocks[stableCount].content != content {
            blocks[stableCount].setContent(content)
        }
    }

    /// How many leading blocks are finalized. Normally all but the last — but a
    /// `.list` at the stable boundary is held back too: the trailing partial
    /// block can still merge INTO it (a lone "3" parses as a paragraph until
    /// "3." arrives, then joins the preceding list), so sealing the list would
    /// freeze it split. The mutable tail is then list + partial — still O(tail).
    private func stableBlockCount() -> Int {
        guard blocks.count > 1 else { return 0 }
        var count = blocks.count - 1
        if count > 0, case .list = blocks[count - 1].content {
            count -= 1
        }
        return count
    }

    /// True when `markdown`'s first `stableUTF8Offset` bytes match the previous
    /// text — i.e. the stable prefix is untouched and the incremental tail path
    /// is valid. Byte-compares just the stable region instead of running
    /// `hasPrefix(previousMarkdown)` over the whole previous string.
    ///
    /// PERF: generic document updates pay this cost when they have a stable
    /// prefix; chat's known-append path bypasses it. Comparing contiguous UTF-8
    /// buffers keeps the defensive path much cheaper than grapheme iteration.
    private func hasUnchangedStablePrefix(_ markdown: String) -> Bool {
        let a = markdown.utf8
        let b = previousMarkdown.utf8
        guard a.count >= stableUTF8Offset, b.count >= stableUTF8Offset else { return false }
        if stableUTF8Offset == 0 { return true }
        let result = a.withContiguousStorageIfAvailable { ap in
            b.withContiguousStorageIfAvailable { bp in
                memcmp(ap.baseAddress!, bp.baseAddress!, stableUTF8Offset) == 0
            }
        }
        // Both views were contiguous (the native-String norm) → use that result;
        // otherwise fall back to the element compare.
        if let outer = result, let equal = outer { return equal }
        return a.prefix(stableUTF8Offset).elementsEqual(b.prefix(stableUTF8Offset))
    }

    /// Refreshes `tailLines` to describe `markdown[stableUTF8Offset...]`. A pure
    /// append over a still-valid cache only splits the appended bytes: they
    /// extend the final (incomplete) line and add whatever newlines they carry.
    private func refreshTailLines(markdown: String, isAppend: Bool, previousUTF8Count: Int) {
        let utf8 = markdown.utf8
        if isAppend, tailLinesValid, !tailLines.isEmpty, previousUTF8Count >= stableUTF8Offset {
            let appended = utf8.index(utf8.startIndex, offsetBy: previousUTF8Count)
            var isFirstSegment = true
            MarkdownParser.forEachASCIIField(utf8[appended...], separator: 0x0A) { segment in
                if isFirstSegment {
                    tailLines[tailLines.count - 1] += segment
                    isFirstSegment = false
                } else {
                    tailLines.append(segment)
                }
            }
            return
        }
        let tailStart = utf8.index(utf8.startIndex, offsetBy: stableUTF8Offset)
        tailLines = MarkdownParser.splitASCII(String(markdown[tailStart...]), separator: 0x0A)
        tailLinesValid = true
    }

    /// Index of the line where block `blockCount` begins (past the first
    /// `blockCount` blocks and any blank lines that follow them).
    private static func sourceLineCount(forBlocks blockCount: Int, in lines: [String]) -> Int {
        var index = 0
        var blocksFound = 0

        while index < lines.count && blocksFound < blockCount {
            let result = MarkdownParser.parseNextBlock(lines: lines, startIndex: index)
            index = max(result.nextIndex, index + 1)
            if result.block != nil { blocksFound += 1 }
        }

        // Skip any trailing blank lines so the offset starts clean
        while index < lines.count && MarkdownParser.isHorizontalWhitespaceOnly(lines[index]) {
            index += 1
        }
        return min(index, lines.count)
    }

    /// Reconcile only from `startIndex` onward with new tail blocks.
    private func reconcileTail(_ tailContents: [MarkdownBlockContent], from startIndex: Int) {
        let totalNeeded = startIndex + tailContents.count

        // Update existing blocks in the tail region
        for i in 0..<tailContents.count {
            let blockIdx = startIndex + i
            if blockIdx < blocks.count {
                if blocks[blockIdx].content != tailContents[i] {
                    blocks[blockIdx].setContent(tailContents[i])
                }
            } else {
                blocks.append(StableBlock(content: tailContents[i]))
            }
        }

        // Trim excess blocks beyond what we need
        if blocks.count > totalNeeded {
            blocks.removeSubrange(totalNeeded...)
        }
    }

}

// MARK: - Stateless Parser

struct MarkdownParser {

    struct SourceParseResult {
        /// nil for source that is intentionally consumed without rendering
        /// (blank lines and skipped HTML media).
        let block: MarkdownBlockContent?
        let nextIndex: Int
    }

    /// ASCII separators cannot occur inside a multi-byte UTF-8 scalar. Splitting
    /// the byte view preserves empty fields while avoiding Foundation's
    /// normalization-aware substring search.
    static func splitASCII(_ source: String, separator: UInt8) -> [String] {
        let bytes = source.utf8
        if let fields = bytes.withContiguousStorageIfAvailable({ buffer in
            var result: [String] = []
            // Most incremental tails are short; cover them in one allocation
            // without sizing a large array from an unusually long source line.
            result.reserveCapacity(min(32, buffer.count + 1))
            var fieldStart = buffer.startIndex
            var index = fieldStart
            while index < buffer.endIndex {
                if buffer[index] == separator {
                    result.append(String(decoding: buffer[fieldStart..<index], as: UTF8.self))
                    fieldStart = index + 1
                }
                index += 1
            }
            result.append(String(decoding: buffer[fieldStart..<buffer.endIndex], as: UTF8.self))
            return result
        }) {
            return fields
        }
        return bytes.split(separator: separator, omittingEmptySubsequences: false).map {
            String(decoding: $0, as: UTF8.self)
        }
    }

    /// `splitASCII` over a UTF-8 slice, yielding each field without building the
    /// slice's own String first. The streaming parser splits only its appended
    /// bytes this way, so a flush allocates per new line instead of per tail.
    static func forEachASCIIField(
        _ bytes: String.UTF8View.SubSequence, separator: UInt8, _ body: (String) -> Void
    ) {
        let handled: Void? = bytes.withContiguousStorageIfAvailable { buffer in
            var fieldStart = 0
            for index in 0..<buffer.count where buffer[index] == separator {
                body(String(decoding: buffer[fieldStart..<index], as: UTF8.self))
                fieldStart = index + 1
            }
            body(String(decoding: buffer[fieldStart...], as: UTF8.self))
        }
        if handled != nil { return }
        for field in bytes.split(separator: separator, omittingEmptySubsequences: false) {
            body(String(decoding: field, as: UTF8.self))
        }
    }

    @inline(__always)
    static func containsByte<Bytes: Collection>(_ bytes: Bytes, _ byte: UInt8) -> Bool
    where Bytes.Element == UInt8 {
        if bytes.isEmpty { return false }
        if let result = bytes.withContiguousStorageIfAvailable({ buffer in
            memchr(buffer.baseAddress!, Int32(byte), buffer.count) != nil
        }) {
            return result
        }
        return bytes.contains(byte)
    }

    @inline(__always)
    static func isASCIIWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || (byte >= 0x09 && byte <= 0x0D)
    }

    @inline(__always)
    static func isHorizontalWhitespace(_ scalar: UnicodeScalar) -> Bool {
        scalar.value == 0x09 || scalar.value == 0x20
            || (scalar.value >= 0x80 && CharacterSet.whitespaces.contains(scalar))
    }

    /// Byte-level trim for the overwhelmingly common all-ASCII line. Returns nil
    /// when any byte is non-ASCII, where Unicode whitespace classification (and
    /// scalar boundaries) must decide instead.
    @inline(__always)
    private static func trimmingASCIIHorizontalWhitespace(_ source: String) -> String?? {
        source.utf8.withContiguousStorageIfAvailable { buffer -> String? in
            var start = 0
            var end = buffer.count
            while start < end {
                let byte = buffer[start]
                if byte >= 0x80 { return nil }
                guard byte == 0x20 || byte == 0x09 else { break }
                start += 1
            }
            while end > start {
                let byte = buffer[end - 1]
                if byte >= 0x80 { return nil }
                guard byte == 0x20 || byte == 0x09 else { break }
                end -= 1
            }
            if start == 0 && end == buffer.count { return source }
            return String(decoding: buffer[start..<end], as: UTF8.self)
        }
    }

    static func trimmingHorizontalWhitespace(_ source: String) -> String {
        if let contiguous = trimmingASCIIHorizontalWhitespace(source), let trimmed = contiguous {
            return trimmed
        }
        let scalars = source.unicodeScalars
        var start = scalars.startIndex
        var end = scalars.endIndex
        while start < end, isHorizontalWhitespace(scalars[start]) {
            start = scalars.index(after: start)
        }
        while end > start {
            let previous = scalars.index(before: end)
            guard isHorizontalWhitespace(scalars[previous]) else { break }
            end = previous
        }
        guard start != scalars.startIndex || end != scalars.endIndex else { return source }
        return String(scalars[start..<end])
    }

    static func isHorizontalWhitespaceOnly(_ source: String) -> Bool {
        let ascii = source.utf8.withContiguousStorageIfAvailable { buffer -> Bool? in
            for byte in buffer {
                if byte >= 0x80 { return nil }
                if byte != 0x20 && byte != 0x09 { return false }
            }
            return true
        }
        if let contiguous = ascii, let result = contiguous { return result }
        return source.unicodeScalars.allSatisfy(isHorizontalWhitespace)
    }

    @inline(__always)
    static func isTrimmableWhitespace(_ character: Character) -> Bool {
        // CharacterSet.whitespacesAndNewlines additionally contains U+200B on
        // Apple platforms; keep boundary fast paths identical to Foundation.
        character.isWhitespace || character == "\u{200B}"
    }

    /// `trimmingCharacters(in: .whitespacesAndNewlines)` without its copy when
    /// there is nothing to trim — the streaming case, where a growing block's
    /// text is rebuilt on every flush.
    @inline(__always)
    static func trimmedIfNeeded(_ text: String) -> String {
        let needsTrim = text.first.map(isTrimmableWhitespace) == true
            || text.last.map(isTrimmableWhitespace) == true
        return needsTrim ? text.trimmingCharacters(in: .whitespacesAndNewlines) : text
    }

    /// Returns the first non-whitespace ASCII byte, `-1` for an empty/blank
    /// ASCII line, or `-2` when Unicode classification is required.
    @inline(__always)
    static func leadingASCIIByte(_ source: String) -> Int {
        for byte in source.utf8 {
            if isASCIIWhitespace(byte) { continue }
            return byte < 0x80 ? Int(byte) : -2
        }
        return -1
    }

    /// Parse a raw markdown string into an array of block contents.
    static func parse(_ markdown: String) -> [MarkdownBlockContent] {
        // Most streamed prose starts as one ordinary line. In that case the
        // block parse is already determined, and the paragraph parser would
        // only split, probe, join, and trim the same String. Reuse its storage
        // directly; marker-led or leading-whitespace lines keep the full path.
        if let text = plainSingleLineParagraphText(markdown) {
            return [.paragraph(text: text, alignment: .leading)]
        }

        return parse(lines: splitASCII(markdown, separator: 0x0A))
    }

    /// Parse pre-split source lines. The streaming parser keeps its tail's lines
    /// across updates and enters here, so an append does not re-split — and
    /// re-allocate — every line of the block it is still growing.
    static func parse(lines: [String]) -> [MarkdownBlockContent] {
        var blocks: [MarkdownBlockContent] = []
        blocks.reserveCapacity(min(lines.count, 32))
        var index = 0

        while index < lines.count {
            let result = parseNextBlock(lines: lines, startIndex: index)
            if let block = result.block { blocks.append(block) }
            // Every parser is expected to advance, but keep this outer guard so a
            // malformed future parser cannot spin the main thread forever.
            index = max(result.nextIndex, index + 1)
        }

        return blocks
    }

    static func plainSingleLineParagraphText(_ markdown: String) -> String? {
        guard !containsByte(markdown.utf8, 0x0A),
              let first = markdown.first,
              let last = markdown.last,
              !isTrimmableWhitespace(first),
              first != "`", first != "~", first != "$", first != "<",
              first != "-", first != "*", first != "_", first != "#",
              first != ">", first != "+", !first.isNumber else {
            return nil
        }
        return isTrimmableWhitespace(last)
            ? markdown.trimmingCharacters(in: .whitespacesAndNewlines)
            : markdown
    }

    /// Parses one source block. The first non-whitespace character cheaply gates
    /// syntax-specific parsers, so ordinary prose does not repeatedly trim and
    /// inspect the full line for fences, math, HTML, rules, headings, quotes, and
    /// lists before reaching the paragraph path. Long streaming paragraphs are
    /// the hot case, and each avoided probe otherwise walks their entire tail.
    static func parseNextBlock(lines: [String], startIndex: Int) -> SourceParseResult {
        let line = lines[startIndex]
        // ASCII covers markdown's syntax markers and the overwhelmingly common
        // source path. Unicode-leading lines retain Character classification.
        let leadingByte = leadingASCIIByte(line)
        let unicodeFirst = leadingByte == -2
            ? line.first(where: { !$0.isWhitespace })
            : nil

        if leadingByte == 0x60 || leadingByte == 0x7E
            || unicodeFirst == "`" || unicodeFirst == "~",
           let result = parseFencedCodeBlock(lines: lines, startIndex: startIndex) {
            return SourceParseResult(block: result.block, nextIndex: result.nextIndex)
        }
        if leadingByte == 0x24 || unicodeFirst == "$",
           let result = parseMathBlock(lines: lines, startIndex: startIndex) {
            return SourceParseResult(block: result.block, nextIndex: result.nextIndex)
        }
        if leadingByte == 0x3C || unicodeFirst == "<",
           let result = parseHTMLBlock(lines: lines, startIndex: startIndex) {
            return SourceParseResult(block: result.block, nextIndex: result.nextIndex)
        }
        if leadingByte == 0x2D || leadingByte == 0x2A || leadingByte == 0x5F
            || unicodeFirst == "-" || unicodeFirst == "*" || unicodeFirst == "_",
           isThematicBreak(line) {
            return SourceParseResult(block: .thematicBreak, nextIndex: startIndex + 1)
        }
        if leadingByte == 0x23 || unicodeFirst == "#", let heading = parseHeading(line) {
            return SourceParseResult(block: heading, nextIndex: startIndex + 1)
        }
        if startIndex + 1 < lines.count,
           isTableDelimiterRow(lines[startIndex + 1]),
           let result = parseTable(lines: lines, startIndex: startIndex) {
            return SourceParseResult(block: result.block, nextIndex: result.nextIndex)
        }
        if leadingByte == 0x3E || unicodeFirst == ">" {
            let result = parseBlockQuote(lines: lines, startIndex: startIndex)
            return SourceParseResult(block: result.block, nextIndex: result.nextIndex)
        }
        let startsASCIINumber = leadingByte >= 0x30 && leadingByte <= 0x39
        if leadingByte == 0x2D || leadingByte == 0x2A || leadingByte == 0x2B
            || unicodeFirst == "-" || unicodeFirst == "*" || unicodeFirst == "+"
            || startsASCIINumber || unicodeFirst?.isNumber == true,
           let result = parseList(lines: lines, startIndex: startIndex) {
            return SourceParseResult(block: result.block, nextIndex: result.nextIndex)
        }
        if leadingByte == -1 || (leadingByte == -2 && unicodeFirst == nil) {
            return SourceParseResult(block: nil, nextIndex: startIndex + 1)
        }

        let result = parseParagraph(lines: lines, startIndex: startIndex)
        return SourceParseResult(block: result.block, nextIndex: result.nextIndex)
    }
}

// MARK: - Individual Parsers

extension MarkdownParser {

    struct ParseResult {
        let block: MarkdownBlockContent
        let nextIndex: Int
    }

    // MARK: Fenced Code Block

    static func parseFencedCodeBlock(lines: [String], startIndex: Int) -> ParseResult? {
        let trimmed = lines[startIndex].trimmingCharacters(in: .whitespaces)
        let fence: String
        if trimmed.hasPrefix("```") {
            fence = "```"
        } else if trimmed.hasPrefix("~~~") {
            fence = "~~~"
        } else {
            return nil
        }

        let afterFence = String(trimmed.dropFirst(fence.count)).trimmingCharacters(in: .whitespaces)
        let language = afterFence.isEmpty ? nil : afterFence

        // A streaming fence re-parses its whole body on every flush, so the
        // closing-fence probe runs per line per update. Byte-scanning it, and
        // appending into the code string directly, keeps that probe allocation
        // free instead of trimming a fresh String for every body line.
        let fenceByte = trimmed.utf8.first ?? 0x60
        var code = ""
        var i = startIndex + 1
        while i < lines.count {
            if hasFencePrefix(lines[i], fenceByte) {
                i += 1
                break
            }
            if i > startIndex + 1 { code.append("\n") }
            code += lines[i]
            i += 1
        }

        return ParseResult(block: .codeBlock(language: language, code: code), nextIndex: i)
    }

    /// True when `line`, ignoring leading whitespace, opens with three `marker`
    /// bytes — the closing-fence test, without the trimmed copy it used to make.
    @inline(__always)
    static func hasFencePrefix(_ line: String, _ marker: UInt8) -> Bool {
        let ascii = line.utf8.withContiguousStorageIfAvailable { buffer -> Bool? in
            var index = 0
            while index < buffer.count {
                let byte = buffer[index]
                if byte >= 0x80 { return nil }
                guard byte == 0x20 || byte == 0x09 else { break }
                index += 1
            }
            guard index + 3 <= buffer.count else { return false }
            return buffer[index] == marker && buffer[index + 1] == marker
                && buffer[index + 2] == marker
        }
        if let contiguous = ascii, let result = contiguous { return result }
        let fence = marker == 0x7E ? "~~~" : "```"
        return line.trimmingCharacters(in: .whitespaces).hasPrefix(fence)
    }

    // MARK: Math Block

    /// Parse a `$$ … $$` display-math block. Two shapes are recognized:
    ///
    /// - **Single line** — `$$ E = mc^2 $$` on one line.
    /// - **Fenced** — a bare `$$` opening its own line, body LaTeX lines, then a
    ///   bare `$$` (or a line ending in `$$`) closing it. This is the shape the
    ///   agents emit.
    ///
    /// The opening fence must be a *bare* `$$` line (or a complete single-line
    /// form) so prose like `"$$5 each"` isn't mistaken for a math fence.
    ///
    /// While streaming, an unterminated fence consumes the remaining lines and
    /// returns `complete: false` — the renderer draws it at zero height until the
    /// closing `$$` arrives, so no broken LaTeX flashes mid-stream.
    static func parseMathBlock(lines: [String], startIndex: Int) -> ParseResult? {
        let trimmed = lines[startIndex].trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("$$") else { return nil }

        // Single-line form: $$ … $$
        if trimmed.count >= 4, trimmed.hasSuffix("$$") {
            let inner = String(trimmed.dropFirst(2).dropLast(2))
                .trimmingCharacters(in: .whitespaces)
            if !inner.isEmpty {
                return ParseResult(block: .math(latex: inner, complete: true), nextIndex: startIndex + 1)
            }
        }

        // Fenced form: only a bare "$$" opens a multi-line fence.
        guard trimmed == "$$" else { return nil }

        var body: [String] = []
        body.reserveCapacity(min(max(0, lines.count - startIndex - 1), 16))
        var i = startIndex + 1
        var closed = false
        while i < lines.count {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t == "$$" {
                i += 1
                closed = true
                break
            }
            if t.hasSuffix("$$") {
                let lead = String(t.dropLast(2)).trimmingCharacters(in: .whitespaces)
                if !lead.isEmpty { body.append(lead) }
                i += 1
                closed = true
                break
            }
            body.append(lines[i])
            i += 1
        }

        let latex = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return ParseResult(block: .math(latex: latex, complete: closed), nextIndex: i)
    }

    // MARK: Heading

    private enum HeadingScan {
        case notHeading
        case heading(level: Int, text: String)
        /// Unicode whitespace sits on a boundary; Foundation has to trim it.
        case needsUnicode
    }

    /// One byte pass over an ASCII heading line. The general path allocates
    /// three strings — trim, drop the markers, trim again — and a streaming
    /// heading pays them on every flush until its line ends.
    private static func scanASCIIHeading(_ line: String) -> HeadingScan {
        line.utf8.withContiguousStorageIfAvailable { buffer -> HeadingScan in
            @inline(__always) func isSpace(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x09 }
            var start = 0
            var end = buffer.count
            while start < end {
                if buffer[start] >= 0x80 { return .needsUnicode }
                guard isSpace(buffer[start]) else { break }
                start += 1
            }
            while end > start {
                if buffer[end - 1] >= 0x80 { return .needsUnicode }
                guard isSpace(buffer[end - 1]) else { break }
                end -= 1
            }

            var level = 0
            var index = start
            while index < end, buffer[index] == 0x23 {
                level += 1
                index += 1
            }
            guard level >= 1, level <= 6 else { return .notHeading }
            // A tab after the markers is not a heading — matching `rest.first`.
            if index < end, buffer[index] != 0x20 { return .notHeading }
            while index < end {
                if buffer[index] >= 0x80 { return .needsUnicode }
                guard isSpace(buffer[index]) else { break }
                index += 1
            }
            return .heading(
                level: level, text: String(decoding: buffer[index..<end], as: UTF8.self))
        } ?? .needsUnicode
    }

    static func parseHeading(_ line: String) -> MarkdownBlockContent? {
        switch scanASCIIHeading(line) {
        case .notHeading:
            return nil
        case .heading(let level, let text):
            return .heading(level: level, text: text, alignment: .leading)
        case .needsUnicode:
            break
        }

        let trimmed = line.trimmingCharacters(in: .whitespaces)
        var level = 0
        for char in trimmed {
            if char == "#" { level += 1 } else { break }
        }
        guard level >= 1, level <= 6 else { return nil }
        let rest = String(trimmed.dropFirst(level))
        guard rest.first == " " || rest.isEmpty else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
        return .heading(level: level, text: text, alignment: .leading)
    }

    // MARK: Thematic Break

    static func isThematicBreak(_ line: String) -> Bool {
        let trimmed = trimmingHorizontalWhitespace(line)
        guard let marker = trimmed.utf8.first,
              marker == 0x2D || marker == 0x2A || marker == 0x5F else {
            return false
        }
        var count = 0
        for byte in trimmed.utf8 {
            count += 1
            if byte != 0x20, byte != marker { return false }
        }
        return count >= 3
    }

    // MARK: Block Quote

    /// The quoted text of one line, or nil when the line isn't part of a quote.
    /// Shared with the streaming parser, which folds one line at a time.
    static func blockQuoteLineContent(_ line: String) -> Substring? {
        let trimmed = trimmingHorizontalWhitespace(line)
        guard trimmed.utf8.first == 0x3E else { return nil }
        let content = trimmed.dropFirst(1)
        return content.utf8.first == 0x20 ? content.dropFirst(1) : content
    }

    static func parseBlockQuote(lines: [String], startIndex: Int) -> ParseResult {
        // Appends straight into the joined text: a streaming quote re-parses its
        // whole run on every flush, so the per-line array and `joined` it used to
        // build were the dominant allocation.
        var text = ""
        var hasQuotedLine = false
        var i = startIndex
        while i < lines.count {
            if let content = blockQuoteLineContent(lines[i]) {
                if hasQuotedLine { text.append("\n") }
                text += content
                hasQuotedLine = true
            } else if isHorizontalWhitespaceOnly(lines[i]), hasQuotedLine {
                guard i + 1 < lines.count,
                      blockQuoteLineContent(lines[i + 1]) != nil else {
                    break
                }
                text.append("\n")
            } else {
                break
            }
            i += 1
        }
        return ParseResult(block: .blockQuote(text: trimmedIfNeeded(text)), nextIndex: i)
    }

    // MARK: List

    /// Consume the maximal contiguous run of list-item lines (any marker type,
    /// any depth) into ONE `.list` block. Blank lines stay inside the run only
    /// when another list item follows them, so a loose list ("1. a\n\n2. b")
    /// still parses as a single list instead of one block per item.
    static func parseList(lines: [String], startIndex: Int) -> ParseResult? {
        guard let first = parseListItemLine(lines[startIndex]) else { return nil }

        var items: [MarkdownListItemData] = []
        items.reserveCapacity(4)
        items.append(first)
        var i = startIndex + 1
        while i < lines.count {
            let line = lines[i]
            if let item = parseListItemLine(line) {
                // Only an unordered item whose text starts with another rule
                // marker can be a thematic break such as "- - -".
                if !item.ordered,
                   startsWithThematicBreakMarker(item.text),
                   isThematicBreak(line) {
                    break
                }
                items.append(item)
                i += 1
            } else if isHorizontalWhitespaceOnly(line) {
                var j = i + 1
                while j < lines.count, isHorizontalWhitespaceOnly(lines[j]) {
                    j += 1
                }
                guard j < lines.count, let nextItem = parseListItemLine(lines[j]) else { break }
                if !nextItem.ordered,
                   startsWithThematicBreakMarker(nextItem.text),
                   isThematicBreak(lines[j]) {
                    break
                }
                i = j
            } else {
                break
            }
        }

        // The run consumed through the end of the source → the final item sits
        // on the source's last line and may still be streaming in.
        if i >= lines.count, !items.isEmpty {
            items[items.count - 1].open = true
        }

        return ParseResult(block: .list(items: items), nextIndex: i)
    }

    /// A GFM table delimiter row (`| --- | :-: |`). A single pass replaces two
    /// `contains` scans, an allocated trimmed copy, and Foundation regex matching.
    static func isTableDelimiterRow(_ line: String) -> Bool {
        var hasPipe = false
        var hasHyphen = false
        for byte in line.utf8 {
            switch byte {
            case 0x7C: hasPipe = true
            case 0x2D: hasHyphen = true
            case 0x3A: continue
            default:
                if byte >= 0x80 { return isUnicodeTableDelimiterRow(line) }
                if !isASCIIWhitespace(byte) { return false }
            }
        }
        return hasPipe && hasHyphen
    }

    private static func isUnicodeTableDelimiterRow(_ line: String) -> Bool {
        var hasPipe = false
        var hasHyphen = false
        for character in line {
            switch character {
            case "|": hasPipe = true
            case "-": hasHyphen = true
            case ":": continue
            default:
                if !character.isWhitespace { return false }
            }
        }
        return hasPipe && hasHyphen
    }

    @inline(__always)
    static func startsWithThematicBreakMarker(_ text: String) -> Bool {
        switch leadingASCIIByte(text) {
        case 0x2D, 0x2A, 0x5F:
            return true
        case -2:
            let first = text.first(where: { !$0.isWhitespace })
            return first == "-" || first == "*" || first == "_"
        default:
            return false
        }
    }

    /// Parse a single line as a list item (unordered `-`/`*`/`+` or ordered `1.`).
    static func parseListItemLine(_ line: String) -> MarkdownListItemData? {
        // Strip zero-width spaces that remend's setext handler may add. The
        // first UTF-8 byte gates the scalar scan and allocating replacement.
        let hasZeroWidthSpace = containsByte(line.utf8, 0xE2)
            && line.unicodeScalars.contains(where: { $0.value == 0x200B })
        let cleaned =
            hasZeroWidthSpace
            ? line.replacingOccurrences(of: "\u{200B}", with: "")
            : line

        let bytes = cleaned.utf8
        var cursor = bytes.startIndex
        var spaces = 0
        var tabs = 0
        while cursor < bytes.endIndex {
            if bytes[cursor] == 0x20 {
                spaces += 1
            } else if bytes[cursor] == 0x09 {
                tabs += 1
            } else {
                if bytes[cursor] >= 0x80 || isASCIIWhitespace(bytes[cursor]) {
                    return parseUnicodeListItemLine(cleaned)
                }
                break
            }
            cursor = bytes.index(after: cursor)
        }
        guard cursor < bytes.endIndex else { return nil }
        let depth = tabs + spaces / 2
        let marker = bytes[cursor]

        // Unordered: -, *, +
        if marker == 0x2D || marker == 0x2A || marker == 0x2B {
            let afterMarker = bytes.index(after: cursor)
            guard afterMarker < bytes.endIndex else {
                return MarkdownListItemData(
                    depth: depth, ordered: false, index: 0, text: "")
            }
            if bytes[afterMarker] >= 0x80 {
                return parseUnicodeListItemLine(cleaned)
            }
            guard isASCIIWhitespace(bytes[afterMarker]) else { return nil }

            // `trimmingCharacters(in: .whitespaces)` also removes non-ASCII
            // whitespace at the end. Keep that uncommon case on the Unicode
            // path instead of changing the parsed item text.
            if bytes.last.map({ $0 >= 0x80 }) == true,
               cleaned.unicodeScalars.last.map(CharacterSet.whitespaces.contains) == true {
                return parseUnicodeListItemLine(cleaned)
            }

            var textEnd = bytes.endIndex
            while textEnd > afterMarker {
                let previous = bytes.index(before: textEnd)
                guard bytes[previous] == 0x20 || bytes[previous] == 0x09 else { break }
                textEnd = previous
            }
            let textStart = bytes.index(after: afterMarker)
            let text = textStart < textEnd
                ? String(decoding: bytes[textStart..<textEnd], as: UTF8.self)
                : ""
            return MarkdownListItemData(depth: depth, ordered: false, index: 0, text: text)
        }

        // Ordered: 1. 2. etc
        let digitsStart = cursor
        var itemIndex = 0
        var indexOverflowed = false
        while cursor < bytes.endIndex, bytes[cursor] >= 0x30, bytes[cursor] <= 0x39 {
            if !indexOverflowed {
                let (multiplied, multiplyOverflow) = itemIndex.multipliedReportingOverflow(by: 10)
                let (advanced, addOverflow) = multiplied.addingReportingOverflow(
                    Int(bytes[cursor] - 0x30))
                indexOverflowed = multiplyOverflow || addOverflow
                if !indexOverflowed { itemIndex = advanced }
            }
            cursor = bytes.index(after: cursor)
        }
        if cursor < bytes.endIndex, bytes[cursor] >= 0x80 {
            return parseUnicodeListItemLine(cleaned)
        }
        guard cursor > digitsStart, cursor < bytes.endIndex, bytes[cursor] == 0x2E else {
            return nil
        }
        cursor = bytes.index(after: cursor)
        if cursor < bytes.endIndex {
            if bytes[cursor] >= 0x80 { return parseUnicodeListItemLine(cleaned) }
            guard isASCIIWhitespace(bytes[cursor]) else { return nil }
            while cursor < bytes.endIndex {
                if bytes[cursor] >= 0x80 { return parseUnicodeListItemLine(cleaned) }
                if !isASCIIWhitespace(bytes[cursor]) { break }
                cursor = bytes.index(after: cursor)
            }
        }
        // ICU's `$` anchor matches before a final CR in CRLF input, so the old
        // regex excluded that terminator from ordered-item text.
        var textEnd = bytes.endIndex
        if let last = bytes.last, last == 0x0A || last == 0x0D {
            textEnd = bytes.index(before: textEnd)
        } else if bytes.last.map({ $0 >= 0x80 }) == true,
                  cleaned.last?.isNewline == true {
            return parseUnicodeListItemLine(cleaned)
        }
        let text = cursor < textEnd
            ? String(decoding: bytes[cursor..<textEnd], as: UTF8.self)
            : ""

        return MarkdownListItemData(
            depth: depth, ordered: true, index: indexOverflowed ? 1 : itemIndex, text: text)
    }

    private static func parseUnicodeListItemLine(_ line: String) -> MarkdownListItemData? {
        var cursor = line.startIndex
        var spaces = 0
        var tabs = 0
        var countsTowardDepth = true
        while cursor < line.endIndex, line[cursor].isWhitespace {
            if countsTowardDepth, line[cursor] == " " {
                spaces += 1
            } else if countsTowardDepth, line[cursor] == "\t" {
                tabs += 1
            } else {
                countsTowardDepth = false
            }
            cursor = line.index(after: cursor)
        }
        guard cursor < line.endIndex else { return nil }
        let depth = tabs + spaces / 2
        let marker = line[cursor]

        if marker == "-" || marker == "*" || marker == "+" {
            let afterMarker = line.index(after: cursor)
            guard afterMarker == line.endIndex || line[afterMarker].isWhitespace else {
                return nil
            }
            let stripped = line.trimmingCharacters(in: .whitespaces)
            let text = stripped.count > 1 ? String(stripped.dropFirst(2)) : ""
            return MarkdownListItemData(depth: depth, ordered: false, index: 0, text: text)
        }

        let digitsStart = cursor
        while cursor < line.endIndex,
              line[cursor].unicodeScalars.allSatisfy({
                  $0.properties.generalCategory == .decimalNumber
              }) {
            cursor = line.index(after: cursor)
        }
        guard cursor > digitsStart, cursor < line.endIndex, line[cursor] == "." else {
            return nil
        }
        let itemIndex = Int(line[digitsStart..<cursor]) ?? 1
        cursor = line.index(after: cursor)
        guard cursor == line.endIndex || line[cursor].isWhitespace else { return nil }
        while cursor < line.endIndex, line[cursor].isWhitespace {
            cursor = line.index(after: cursor)
        }
        let textEnd = line.last?.isNewline == true
            ? line.index(before: line.endIndex)
            : line.endIndex
        let text = cursor < textEnd ? String(line[cursor..<textEnd]) : ""
        return MarkdownListItemData(
            depth: depth, ordered: true, index: itemIndex, text: text)
    }

    // MARK: Table

    /// Splits one all-ASCII table row into trimmed cells in a single byte pass.
    /// The general path trims the row, copies it without its edge pipes, splits,
    /// then trims every field again — four allocations per cell, repaid on every
    /// streamed flush because a growing table re-parses all of its rows. Returns
    /// nil for non-ASCII rows, where Unicode whitespace has to decide the edges.
    private static func parseASCIITableCells(_ line: String) -> [String]? {
        line.utf8.withContiguousStorageIfAvailable { buffer -> [String]? in
            for byte in buffer where byte >= 0x80 { return nil }
            @inline(__always) func isSpace(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x09 }
            var low = 0
            var high = buffer.count
            while low < high, isSpace(buffer[low]) { low += 1 }
            while high > low, isSpace(buffer[high - 1]) { high -= 1 }
            if low < high, buffer[low] == 0x7C { low += 1 }
            if high > low, buffer[high - 1] == 0x7C { high -= 1 }

            var cells: [String] = []
            cells.reserveCapacity(4)
            var fieldStart = low
            var index = low
            @inline(__always) func appendCell(_ end: Int) {
                var start = fieldStart
                var stop = end
                while start < stop, isSpace(buffer[start]) { start += 1 }
                while stop > start, isSpace(buffer[stop - 1]) { stop -= 1 }
                cells.append(String(decoding: buffer[start..<stop], as: UTF8.self))
            }
            while index < high {
                if buffer[index] == 0x7C {
                    appendCell(index)
                    fieldStart = index + 1
                }
                index += 1
            }
            appendCell(high)
            return cells
        } ?? nil
    }

    /// The trimmed cells of one table row. Shared with the streaming parser,
    /// which folds one row at a time.
    static func parseTableCells(_ line: String) -> [String] {
        if let ascii = parseASCIITableCells(line) { return ascii }
        let raw = trimmingHorizontalWhitespace(line)
        let start = raw.first == "|" ? raw.index(after: raw.startIndex) : raw.startIndex
        let end = raw.last == "|" && start != raw.endIndex
            ? raw.index(before: raw.endIndex)
            : raw.endIndex
        let cells = start == raw.startIndex && end == raw.endIndex
            ? raw
            : String(raw[start..<end])
        return splitASCII(cells, separator: 0x7C).map {
            trimmingHorizontalWhitespace($0)
        }
    }

    static func parseTable(lines: [String], startIndex: Int) -> ParseResult? {
        guard startIndex + 1 < lines.count else { return nil }

        // A GFM table delimiter row is composed ENTIRELY of pipes, dashes,
        // colons, and whitespace. Whole-line validation prevents list items like
        // "- foo `a|b`" from being swallowed into an empty table.
        guard isTableDelimiterRow(lines[startIndex + 1]) else {
            return nil
        }

        let header = parseTableCells(lines[startIndex])
        guard !header.isEmpty else { return nil }

        var rows: [[String]] = []
        rows.reserveCapacity(min(max(0, lines.count - startIndex - 2), 16))
        var i = startIndex + 2
        while i < lines.count {
            guard containsByte(lines[i].utf8, 0x7C) else { break }
            rows.append(parseTableCells(lines[i]))
            i += 1
        }

        return ParseResult(block: .table(header: header, rows: rows), nextIndex: i)
    }

    // MARK: Paragraph

    static func paragraphEnds(before line: String) -> Bool {
        let firstIndex = line.firstIndex(where: { !$0.isWhitespace })
        let first = firstIndex.map { line[$0] }
        let startsFence = firstIndex.map { index in
            let suffix = line[index...]
            return (first == "`" && suffix.hasPrefix("```"))
                || (first == "~" && suffix.hasPrefix("~~~"))
        } ?? false
        return first == nil || first == "#" || startsFence || first == ">"
            || ((first == "-" || first == "*" || first == "_") && isThematicBreak(line))
    }

    static func canAppendParagraphLines(_ lines: [String], from openLine: Int) -> Bool {
        // A delimiter can reclassify the preceding line as a table header.
        for index in max(0, openLine - 1)..<lines.count {
            if index + 1 < lines.count, isTableDelimiterRow(lines[index + 1]) { return false }
            if index > 0, paragraphEnds(before: lines[index]) {
                guard index == lines.count - 1, isHorizontalWhitespaceOnly(lines[index]) else {
                    return false
                }
            }
        }
        return true
    }

    static func parseParagraph(lines: [String], startIndex: Int) -> ParseResult {
        var i = startIndex
        while i < lines.count {
            let line = lines[i]

            // Break conditions stop a paragraph when a NEW block begins — but they
            // apply only to *continuation* lines (i > startIndex). The first line
            // is always consumed so the parser makes forward progress: parse()
            // routes a line here only as a last resort, and some of those first
            // lines match a break condition (e.g. a "#"-prefixed line that isn't a
            // valid heading, like "#1 applied." — `#` then a non-space). Bailing
            // before consuming it would return nextIndex == startIndex and hang
            // parse()'s loop. Consuming it renders the line as literal paragraph
            // text, which is also what CommonMark does for a non-heading "#…".
            if i > startIndex {
                if paragraphEnds(before: line)
                    || (i + 1 < lines.count && isTableDelimiterRow(lines[i + 1])) {
                    break
                }
            }

            i += 1
        }

        let text: String
        if i == startIndex + 1 {
            let line = lines[startIndex]
            if let first = line.first, let last = line.last,
               !isTrimmableWhitespace(first), !isTrimmableWhitespace(last) {
                text = line
            } else {
                text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } else {
            let joined = lines[startIndex..<i].joined(separator: "\n")
            if let first = joined.first, let last = joined.last,
               !isTrimmableWhitespace(first), !isTrimmableWhitespace(last) {
                text = joined
            } else {
                text = joined.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return ParseResult(block: .paragraph(text: text, alignment: .leading), nextIndex: i)
    }
}

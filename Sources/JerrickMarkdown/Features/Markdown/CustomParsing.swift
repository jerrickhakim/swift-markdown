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
    public var open: Bool

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

    public init() {}

    /// Number of blocks whose content is finalized (won't change with more text).
    private var stableCount = 0
    /// UTF-8 byte offset in the source where the stable prefix ends — the start
    /// of the trailing (still-mutable) block. On next update we only parse from here.
    private var stableUTF8Offset = 0
    /// The previous markdown string, used for the no-change fast path and the
    /// stable-prefix comparison.
    private var previousMarkdown = ""

    /// Re-parse only the trailing portion of the markdown string.
    ///
    /// PERF: every per-update step is O(tail), not O(full text). The previous
    /// version ran `hasPrefix(previousMarkdown)`, a grapheme-walking
    /// `dropFirst(stableOffset)`, and a `components(separatedBy: "\n")` over the
    /// FULL accumulated markdown on every streamed flush — quadratic over a long
    /// response. The stable offset is now byte-based and advanced from the tail
    /// parse alone.
    public func update(markdown: String) {
        // Fast path: if nothing changed, skip entirely
        if markdown == previousMarkdown { return }

        if stableCount > 0, hasUnchangedStablePrefix(markdown) {
            // The stable prefix is still valid — only re-parse the tail. Edits
            // AFTER the stable offset (not just appends) are covered too, since
            // the whole tail is re-parsed and reconciled.
            let utf8 = markdown.utf8
            let tailStart = utf8.index(utf8.startIndex, offsetBy: stableUTF8Offset)
            let tail = String(markdown[tailStart...])
            let tailBlocks = MarkdownParser.parse(tail)

            // stableUTF8Offset points to the start of block[stableCount] (the trailing
            // block), so tailBlocks[0] corresponds to that block. Reconcile from there —
            // not from stableCount - 1, which would clobber the last stable block.
            reconcileTail(tailBlocks, from: stableCount)

            // All blocks except the mutable tail are now "done". Advance the
            // stable offset by where the new trailing region starts WITHIN the
            // tail — no full-string re-scan.
            let newStable = stableBlockCount()
            if newStable > stableCount, !tailBlocks.isEmpty {
                stableUTF8Offset += Self.sourceUTF8Offset(
                    forBlocks: newStable - stableCount, in: tail)
                stableCount = newStable
            }
        } else {
            // Stable prefix changed (replace/edit) or no stable prefix yet — full re-parse.
            stableCount = 0
            stableUTF8Offset = 0
            let newContents = MarkdownParser.parse(markdown)
            reconcileFull(newContents)

            stableCount = stableBlockCount()
            if stableCount > 0 {
                stableUTF8Offset = Self.sourceUTF8Offset(forBlocks: stableCount, in: markdown)
            }
        }

        previousMarkdown = markdown
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
    /// PERF: this runs on EVERY streaming delta and its cost scales with the
    /// settled prefix, so a naive element-by-element compare made the live path
    /// O(n²) over a turn (each token re-walks the whole settled text). Comparing
    /// the contiguous UTF-8 buffers with `memcmp` is the same comparison ~10×
    /// cheaper, which cut streaming a 32KB reply ~3×. (Still O(stable) per delta;
    /// a truly O(tail) version would require the parser to own the accumulated
    /// text — a larger change. See the streaming scaling notes.)
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

    /// UTF-8 byte offset in `markdown` where block `blockCount` begins (the offset
    /// after the first `blockCount` blocks, skipping trailing blank lines). Cost is
    /// O(`markdown`) — the streaming path passes the tail, never the full text.
    private static func sourceUTF8Offset(forBlocks blockCount: Int, in markdown: String) -> Int {
        // Re-parse to find where block N ends. This is cheap since we only
        // parse up to blockCount blocks (usually all but the last).
        let lines = markdown.components(separatedBy: "\n")
        var index = 0
        var blocksFound = 0

        while index < lines.count && blocksFound < blockCount {
            let line = lines[index]

            if let codeResult = MarkdownParser.parseFencedCodeBlock(lines: lines, startIndex: index) {
                _ = codeResult
                index = codeResult.nextIndex
            } else if let mathResult = MarkdownParser.parseMathBlock(lines: lines, startIndex: index) {
                index = mathResult.nextIndex
            } else if let htmlResult = MarkdownParser.parseHTMLBlock(lines: lines, startIndex: index) {
                index = htmlResult.nextIndex
                // A skipped HTML block (e.g. an image) advances the cursor but
                // produces NO block — don't count it, or the block tally drifts
                // from what `parse()` actually emitted and the byte offset skews.
                if htmlResult.block == nil { continue }
            } else if MarkdownParser.isThematicBreak(line) {
                index += 1
            } else if MarkdownParser.parseHeading(line) != nil {
                index += 1
            } else if let tableResult = MarkdownParser.parseTable(lines: lines, startIndex: index) {
                index = tableResult.nextIndex
            } else if line.trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                let bqResult = MarkdownParser.parseBlockQuote(lines: lines, startIndex: index)
                index = bqResult.nextIndex
            } else if let listResult = MarkdownParser.parseList(lines: lines, startIndex: index) {
                index = listResult.nextIndex
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                index += 1
                continue // blank lines don't count as blocks
            } else {
                let paraResult = MarkdownParser.parseParagraph(lines: lines, startIndex: index)
                index = paraResult.nextIndex
            }
            blocksFound += 1
        }

        // Skip any trailing blank lines so the offset starts clean
        while index < lines.count && lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
            index += 1
        }

        // Convert line index back to a UTF-8 byte offset
        var byteOffset = 0
        for i in 0..<min(index, lines.count) {
            byteOffset += lines[i].utf8.count + 1 // +1 for the "\n" separator
        }
        return min(byteOffset, markdown.utf8.count)
    }

    /// Full reconcile — used when text was replaced, not appended.
    private func reconcileFull(_ newContents: [MarkdownBlockContent]) {
        for i in 0..<min(blocks.count, newContents.count) {
            if blocks[i].content != newContents[i] {
                blocks[i].setContent(newContents[i])
            }
        }
        if blocks.count > newContents.count {
            blocks.removeSubrange(newContents.count...)
        }
        if newContents.count > blocks.count {
            for i in blocks.count..<newContents.count {
                blocks.append(StableBlock(content: newContents[i]))
            }
        }
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

    /// Parse a raw markdown string into an array of block contents.
    static func parse(_ markdown: String) -> [MarkdownBlockContent] {
        var blocks: [MarkdownBlockContent] = []
        let lines = markdown.components(separatedBy: "\n")
        var index = 0

        while index < lines.count {
            let line = lines[index]

            // --- Fenced code block (``` or ~~~) ---
            if let codeResult = parseFencedCodeBlock(lines: lines, startIndex: index) {
                blocks.append(codeResult.block)
                index = codeResult.nextIndex
                continue
            }

            // --- Math block ($$ … $$) ---
            if let mathResult = parseMathBlock(lines: lines, startIndex: index) {
                blocks.append(mathResult.block)
                index = mathResult.nextIndex
                continue
            }

            // --- HTML block (<details>, <table>, <pre>, <blockquote>, <p>,
            //     <h1>–<h6>, <img>, <picture>). Inline-only tags (<kbd>, <sup>,
            //     …) are NOT block tags, so a line that opens with one falls
            //     through to the paragraph path and renders via inline HTML. ---
            if let htmlResult = parseHTMLBlock(lines: lines, startIndex: index) {
                if let block = htmlResult.block { blocks.append(block) }
                index = htmlResult.nextIndex
                continue
            }

            // --- Thematic break (---, ***, ___) ---
            if isThematicBreak(line) {
                blocks.append(.thematicBreak)
                index += 1
                continue
            }

            // --- Heading (# … ######) ---
            if let heading = parseHeading(line) {
                blocks.append(heading)
                index += 1
                continue
            }

            // --- Table ---
            if let tableResult = parseTable(lines: lines, startIndex: index) {
                blocks.append(tableResult.block)
                index = tableResult.nextIndex
                continue
            }

            // --- Block quote (>) ---
            if line.trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                let bqResult = parseBlockQuote(lines: lines, startIndex: index)
                blocks.append(bqResult.block)
                index = bqResult.nextIndex
                continue
            }

            // --- List (run of -, *, +, 1. lines → ONE block) ---
            if let listResult = parseList(lines: lines, startIndex: index) {
                blocks.append(listResult.block)
                index = listResult.nextIndex
                continue
            }

            // --- Blank line (skip) ---
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                index += 1
                continue
            }

            // --- Paragraph (default) ---
            let paraResult = parseParagraph(lines: lines, startIndex: index)
            blocks.append(paraResult.block)
            // Defensive: parseParagraph always consumes ≥1 line, but never let a
            // non-advancing parse result spin this loop forever. A stalled parse
            // freezes the main thread, which on iOS reads as the app hanging and
            // then being watchdog-killed (a "crash"). `max` guarantees progress.
            index = max(paraResult.nextIndex, index + 1)
        }

        return blocks
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

        var codeLines: [String] = []
        var i = startIndex + 1
        while i < lines.count {
            if lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                i += 1
                break
            }
            codeLines.append(lines[i])
            i += 1
        }

        let code = codeLines.joined(separator: "\n")
        return ParseResult(block: .codeBlock(language: language, code: code), nextIndex: i)
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

    static func parseHeading(_ line: String) -> MarkdownBlockContent? {
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
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3 else { return false }
        let chars = Set(trimmed.filter { $0 != " " })
        return chars.count == 1 && (chars.contains("-") || chars.contains("*") || chars.contains("_"))
    }

    // MARK: Block Quote

    static func parseBlockQuote(lines: [String], startIndex: Int) -> ParseResult {
        var quoteLines: [String] = []
        var i = startIndex
        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(">") {
                let content = String(trimmed.dropFirst(1))
                quoteLines.append(content.hasPrefix(" ") ? String(content.dropFirst(1)) : content)
            } else if trimmed.isEmpty, !quoteLines.isEmpty {
                if i + 1 < lines.count, lines[i + 1].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    quoteLines.append("")
                } else {
                    break
                }
            } else {
                break
            }
            i += 1
        }
        let text = quoteLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return ParseResult(block: .blockQuote(text: text), nextIndex: i)
    }

    // MARK: List

    /// Consume the maximal contiguous run of list-item lines (any marker type,
    /// any depth) into ONE `.list` block. Blank lines stay inside the run only
    /// when another list item follows them, so a loose list ("1. a\n\n2. b")
    /// still parses as a single list instead of one block per item.
    static func parseList(lines: [String], startIndex: Int) -> ParseResult? {
        guard let first = parseListItemLine(lines[startIndex]) else { return nil }

        var items: [MarkdownListItemData] = [first]
        var i = startIndex + 1
        while i < lines.count {
            let line = lines[i]
            // The outer parse checks thematic breaks before lists; mirror that
            // here so "- - -" mid-run ends the list instead of becoming an item.
            if isThematicBreak(line) { break }

            if let item = parseListItemLine(line) {
                items.append(item)
                i += 1
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                var j = i + 1
                while j < lines.count, lines[j].trimmingCharacters(in: .whitespaces).isEmpty {
                    j += 1
                }
                guard j < lines.count, !isThematicBreak(lines[j]),
                      parseListItemLine(lines[j]) != nil else { break }
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

    /// Compiled ONCE and reused for every line. These previously compiled on
    /// each call — `range(of:options:.regularExpression)` rebuilds the matcher
    /// every time and `NSRegularExpression(pattern:)` was constructed per call —
    /// and because `parseListItemLine` runs on the first line of EVERY block (the
    /// parser tests each block-start for a list marker), that per-call regex
    /// compilation was ~90% of the entire parse cost on a streamed reply.
    /// Caching them cut a full parse ~7× with byte-identical output. See
    /// `MarkdownParserSafetyTests`.
    private static let unorderedListItemRegex = try! NSRegularExpression(
        pattern: #"^(\s*)([-*+])(\s+(.*))?$"#)
    private static let orderedListItemRegex = try! NSRegularExpression(
        pattern: #"^(\s*)(\d+)\.(\s+(.*))?$"#)

    /// A GFM table delimiter row (`| --- | :-: |`) — also cached, also compiled
    /// per call before. Used by `parseTable` and the streaming-table look-ahead
    /// in `parseParagraph`.
    private static let tableDelimiterRegex = try! NSRegularExpression(
        pattern: #"^[\|\s:\-]+$"#)

    /// Whole-string match against `tableDelimiterRegex` (replaces the per-call
    /// `range(of:options:.regularExpression)`).
    static func isTableDelimiterRow(_ s: String) -> Bool {
        tableDelimiterRegex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// Parse a single line as a list item (unordered `-`/`*`/`+` or ordered `1.`).
    static func parseListItemLine(_ line: String) -> MarkdownListItemData? {
        // Strip zero-width spaces that remend's setext handler may add. The
        // allocating replace only runs when one is actually present (rare).
        let cleaned =
            line.contains("\u{200B}")
            ? line.replacingOccurrences(of: "\u{200B}", with: "")
            : line

        let leading = cleaned.prefix(while: { $0 == " " || $0 == "\t" })
        let depth = leading.filter({ $0 == "\t" }).count + leading.filter({ $0 == " " }).count / 2
        let range = NSRange(cleaned.startIndex..., in: cleaned)

        // Unordered: -, *, +
        if Self.unorderedListItemRegex.firstMatch(in: cleaned, range: range) != nil {
            let stripped = cleaned.trimmingCharacters(in: .whitespaces)
            // Bare marker (e.g. "-") → empty list item
            let text = stripped.count > 1 ? String(stripped.dropFirst(2)) : ""
            return MarkdownListItemData(depth: depth, ordered: false, index: 0, text: text)
        }

        // Ordered: 1. 2. etc
        guard let match = Self.orderedListItemRegex.firstMatch(in: cleaned, range: range) else {
            return nil
        }

        // Defensive: group 2 is `(\d+)`, so a successful match always has it —
        // but never force-unwrap in the streaming parse path. If the range can't
        // be mapped, treat the line as not-a-list-item (it falls through to a
        // paragraph) instead of trapping and crashing the app.
        guard let indexRange = Range(match.range(at: 2), in: cleaned) else { return nil }
        let itemIndex = Int(cleaned[indexRange]) ?? 1

        // Group 4 is the text after the space; may be absent for bare markers like "1."
        let textRange = match.range(at: 4).location != NSNotFound
            ? Range(match.range(at: 4), in: cleaned)
            : nil
        let text = textRange.map { String(cleaned[$0]) } ?? ""

        return MarkdownListItemData(depth: depth, ordered: true, index: itemIndex, text: text)
    }

    // MARK: Table

    static func parseTable(lines: [String], startIndex: Int) -> ParseResult? {
        guard startIndex + 1 < lines.count else { return nil }

        let headerLine = lines[startIndex]
        let separatorLine = lines[startIndex + 1]

        let sepTrimmed = separatorLine.trimmingCharacters(in: .whitespaces)
        // A GFM table delimiter row is composed ENTIRELY of pipes, dashes,
        // colons, and whitespace. Anchor to the whole line (^…$) — a prefix-only
        // match falsely treats list items like "- foo `a|b`" (which start with
        // "- " and contain a pipe) as separators, swallowing them into an empty table.
        guard sepTrimmed.contains("|"),
              isTableDelimiterRow(sepTrimmed),
              sepTrimmed.contains("-") else {
            return nil
        }

        func parseCells(_ line: String) -> [String] {
            var raw = line.trimmingCharacters(in: .whitespaces)
            if raw.hasPrefix("|") { raw = String(raw.dropFirst()) }
            if raw.hasSuffix("|") { raw = String(raw.dropLast()) }
            return raw.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        }

        let header = parseCells(headerLine)
        guard !header.isEmpty else { return nil }

        var rows: [[String]] = []
        var i = startIndex + 2
        while i < lines.count {
            let rowLine = lines[i].trimmingCharacters(in: .whitespaces)
            guard rowLine.contains("|"), !rowLine.isEmpty else { break }
            rows.append(parseCells(lines[i]))
            i += 1
        }

        return ParseResult(block: .table(header: header, rows: rows), nextIndex: i)
    }

    // MARK: Paragraph

    static func parseParagraph(lines: [String], startIndex: Int) -> ParseResult {
        var paraLines: [String] = []
        var i = startIndex
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

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
                if trimmed.isEmpty
                    || trimmed.hasPrefix("#")
                    || trimmed.hasPrefix("```")
                    || trimmed.hasPrefix("~~~")
                    || trimmed.hasPrefix(">")
                    || isThematicBreak(line) {
                    break
                }
                if i + 1 < lines.count {
                    let nextTrimmed = lines[i + 1].trimmingCharacters(in: .whitespaces)
                    if nextTrimmed.contains("|"), nextTrimmed.contains("-"),
                       isTableDelimiterRow(nextTrimmed) {
                        break
                    }
                }
            }

            paraLines.append(line)
            i += 1
        }

        let text = paraLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return ParseResult(block: .paragraph(text: text, alignment: .leading), nextIndex: i)
    }
}

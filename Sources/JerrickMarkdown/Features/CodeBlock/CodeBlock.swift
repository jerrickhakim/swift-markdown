import SwiftUI
import UIKit

/// A fenced code block. The container reveals through the shared
/// `MarkdownReveal` (matching every other CustomMarkdown block); the code
/// body is one `CodeStreamingText`, so streamed tokens fade in with the same
/// word wave as prose and the settled block is natively selectable.
public struct CodeBlock: View {
    public var code: String
    public var language: String?
    /// When false, the block renders fully visible with no reveal motion —
    /// used for settled/historical blocks so scrollback doesn't re-animate.
    public var animated: Bool
    /// True while the block is the live streaming tail: highlight requests
    /// are throttled so highlight.js doesn't re-run per flush.
    public var isStreaming: Bool
    public var startDelay: Double
    public var theme: MarkdownTheme

    /// When non-empty, the body renders a unified diff (gutter line numbers,
    /// `+`/`−` prefixes, add/delete row tinting) inside the normal code-block
    /// chrome instead of the plain highlighted code. Used by the edit-tool
    /// dropdown and `diff`-fenced markdown blocks.
    public var diffLines: [MarkdownDiffLine]?
    /// Optional file name shown in the header (diff/edit context). Falls back
    /// to the detected language label when nil.
    public var fileName: String?

    public init(
        code: String = "",
        language: String? = nil,
        animated: Bool = true,
        isStreaming: Bool = false,
        startDelay: Double = 0.3,
        theme: MarkdownTheme = .standard,
        diffLines: [MarkdownDiffLine]? = nil,
        fileName: String? = nil
    ) {
        self.code = code
        self.language = language
        self.animated = animated
        self.isStreaming = isStreaming
        self.startDelay = startDelay
        self.theme = theme
        self.diffLines = diffLines
        self.fileName = fileName
    }

    @Environment(\.colorScheme) private var colorScheme

    @State private var revealed = false
    @State private var highlight = CodeBlockHighlightModel()

    private static let cornerRadius: CGFloat = 16

    /// Equatable key for the highlight task — restarts on content, language,
    /// appearance, or streaming-state changes.
    private struct HighlightRequest: Equatable {
        let code: String
        let language: String?
        let dark: Bool
        let streaming: Bool
    }

    private var isDiff: Bool { !(diffLines?.isEmpty ?? true) }

    public var body: some View {
        // Trim once per render and thread it through. `code.trimmingCharacters`
        // is O(n) and was recomputed independently by `.task(id:)`, `codeLines`,
        // and `lineCountKey` — three full string copies per delta on a streaming
        // block. One copy now feeds all three.
        let trimmed = code.trimmingCharacters(in: .newlines)
        VStack(alignment: .leading, spacing: 0) {
            header
            if let diffLines, isDiff {
                UnifiedDiffView(
                    lines: diffLines,
                    language: highlightLanguage ?? "plaintext",
                    theme: theme
                )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .clipShape(
                        UnevenRoundedRectangle(
                            bottomLeadingRadius: Self.cornerRadius,
                            bottomTrailingRadius: Self.cornerRadius,
                            style: .continuous))
            } else {
                codeLines(trimmed)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .fill(codeBackground)
        }
        // Subtle height settle as new lines stream in: keyed to line count
        // (not raw tokens) so the container grows smoothly without animating
        // every per-token text update inside the body.
        .animation(.smooth(duration: 0.2), value: lineCountKey(trimmed))
        .markdownReveal(revealed, index: 0, startDelay: startDelay)
        // Chat streaming path (animated: false): the blur reveal is off, so
        // fade the container chrome in as the block starts streaming instead
        // of popping the header/background at full strength. Settled blocks
        // (isStreaming: false) render immediately — scrollback never animates.
        .streamingChromeFade(isStreaming && !animated)
        .onAppear {
            if animated {
                revealed = true
            } else {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { revealed = true }
            }
        }
        .task(
            id: HighlightRequest(
                code: trimmed,
                language: highlightLanguage,
                dark: colorScheme == .dark,
                streaming: isStreaming
            )
        ) {
            // Diff mode renders its own per-line tinting via UnifiedDiffView;
            // the whole-block highlighter doesn't apply.
            guard !isDiff else { return }
            highlight.setNeedsHighlight(
                code: trimmed,
                language: highlightLanguage,
                dark: colorScheme == .dark,
                throttled: isStreaming
            )
        }
    }

    // MARK: - Sub-views

    private var header: some View {
        HStack(spacing: 6) {
            if let ext = headerExtension {
                FileTypeIconView(ext: ext, size: 13, fontWeight: .medium, theme: theme)
            }

            Text(headerLabel)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(languageLabelColor)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            CopyButton(code: copySource, colorScheme: colorScheme, theme: theme)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background {
            UnevenRoundedRectangle(
                topLeadingRadius: Self.cornerRadius,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: Self.cornerRadius,
                style: .continuous
            )
            .fill(headerBackground)
        }
    }

    private func codeLines(_ trimmed: String) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            // One UITextView for the whole body: code tokens fade in with the
            // same word wave as prose (shared WordFadeEngine), highlight.js
            // colors land as attribute-only updates that don't disturb
            // in-flight fades, and the block is natively selectable.
            CodeStreamingText(
                code: trimmed,
                highlightedLines: highlight.highlightedLines,
                isStreaming: isStreaming
            )
            .padding(.vertical, 8)
            .padding(.horizontal, 14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Content

    /// Drives the container's height-settle animation: changes once per line
    /// (diff rows or code newlines), not per streamed token.
    private func lineCountKey(_ trimmed: String) -> Int {
        if let diffLines, isDiff { return diffLines.count }
        return trimmed.reduce(into: 1) { count, ch in if ch == "\n" { count += 1 } }
    }

    /// Fence hint for highlight.js (it resolves aliases like `ts`/`py`
    /// natively); nil lets it auto-detect bare ``` fences.
    private var highlightLanguage: String? {
        guard let language = language?.trimmingCharacters(in: .whitespaces).lowercased(),
            !language.isEmpty
        else { return nil }
        return language
    }

    private var displayLanguage: String {
        CodeBlockHelpers.guessFileType(code: code, explicitLanguage: language)
    }

    /// File extension driving the header icon — same icon the file tree uses.
    private var displayExtension: String? {
        CodeBlockHelpers.fileExtension(forLanguage: displayLanguage)
    }

    /// Header text — the file name in diff/edit context, else the language.
    private var headerLabel: String {
        if let fileName, !fileName.isEmpty { return fileName }
        return displayLanguage
    }

    /// Header icon extension — derived from the file name when present, so the
    /// edit dropdown shows the file's real type icon.
    private var headerExtension: String? {
        if let fileName {
            let ext = (fileName as NSString).pathExtension
            if !ext.isEmpty { return ext }
        }
        return displayExtension
    }

    /// What the copy button writes. In diff mode that's the new-side content
    /// (additions + context), so users copy the post-edit text, not the diff.
    private var copySource: String {
        if let diffLines, isDiff {
            return diffLines
                .filter { $0.kind == .addition || $0.kind == .context }
                .map(\.content)
                .joined(separator: "\n")
        }
        return code
    }

    // MARK: - Colors

    private var headerBackground: Color {
        theme.code.headerBackground.resolve(for: colorScheme)
    }

    private var codeBackground: Color {
        theme.code.bodyBackground.resolve(for: colorScheme)
    }

    private var languageLabelColor: Color {
        theme.code.label.resolve(for: colorScheme)
    }
}

// MARK: - Copy button

private struct CopyButton: View {
    let code: String
    let colorScheme: ColorScheme
    let theme: MarkdownTheme

    @State private var showCopied = false
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    var body: some View {
        Button {
            UIPasteboard.general.string = code
            haptic.impactOccurred()
            withAnimation(.easeInOut(duration: 0.15)) { showCopied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation(.easeInOut(duration: 0.15)) { showCopied = false }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: showCopied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .medium))
                    // Pin BOTH dimensions: `checkmark` is intrinsically taller
                    // than `doc.on.doc`, so without a fixed height the icon swap
                    // grew the row and the whole header jumped on tap. 13pt ≈ the
                    // 11pt text line height, so the button stays text-driven.
                    .frame(width: 12, height: 13)
                Text(showCopied ? "Copied" : "Copy")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(showCopied ? copiedForeground : copyButtonColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background {
                Capsule().fill(copyButtonBackground)
            }
        }
        .buttonStyle(.plain)
    }

    private var copyButtonColor: Color {
        theme.code.actionForeground.resolve(for: colorScheme)
    }

    private var copyButtonBackground: Color {
        theme.code.actionBackground.resolve(for: colorScheme)
    }

    private var copiedForeground: Color {
        theme.code.copiedForeground.resolve(for: colorScheme)
    }
}

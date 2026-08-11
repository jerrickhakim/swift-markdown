import SwiftUI

/// Single source of truth for the CustomMarkdown reveal: every component
/// (paragraphs, code blocks, headings, …) fades in with the same
/// blur + float + opacity spring, staggered per unit (word, line, …), so the
/// whole document reads as one continuous motion.
enum MarkdownReveal {
    /// Spring used for every reveal.
    static let spring = Animation.spring(duration: 0.55)
    /// Blur applied while a unit is hidden.
    static let blurRadius: CGFloat = 6
    /// Vertical float distance while a unit is hidden.
    static let yOffset: CGFloat = 6
    /// Stagger between consecutive units within a block.
    static let unitDelay: Double = 0.09
    /// Delay before a block's first unit starts revealing.
    static let startDelay: Double = 0.3
    /// Cap on accumulated stagger so large blocks (long code, big paragraphs)
    /// finish in bounded time instead of trickling in for many seconds.
    static let maxStagger: Double = 1.5
    /// Duration of the plain streaming fades (chrome, table cells) — matches
    /// `WordFadeEngine.fadeDuration` so chrome and words breathe together.
    static let streamFadeDuration: Double = 0.45

    /// The shared animation for the unit at `index` within a block.
    static func animation(
        index: Int,
        unitDelay: Double = MarkdownReveal.unitDelay,
        startDelay: Double = MarkdownReveal.startDelay
    ) -> Animation {
        spring.delay(startDelay + min(Double(index) * unitDelay, maxStagger))
    }
}

/// Fade-in for non-text chrome that appears mid-stream (list markers, quote
/// bars, thematic rules, code-block containers, table chrome). The text word
/// fade lives inside the text views; this gives the chrome around it the same
/// softness instead of popping in at full strength next to fading words.
private struct StreamingChromeFadeModifier: ViewModifier {
    let isStreaming: Bool
    @State private var visible = false

    func body(content: Content) -> some View {
        content
            .opacity(visible || !isStreaming ? 1 : 0)
            .onAppear {
                guard isStreaming, !visible else { return }
                withAnimation(.easeOut(duration: MarkdownReveal.streamFadeDuration)) {
                    visible = true
                }
            }
    }
}

extension View {
    /// Fades the view in on first appearance while its block is streaming.
    /// Settled/history blocks render fully visible with no motion, so
    /// scrollback never re-animates.
    func streamingChromeFade(_ isStreaming: Bool) -> some View {
        modifier(StreamingChromeFadeModifier(isStreaming: isStreaming))
    }
}

private struct MarkdownRevealModifier: ViewModifier {
    let revealed: Bool
    let animation: Animation

    func body(content: Content) -> some View {
        content
            .opacity(revealed ? 1 : 0)
            .blur(radius: revealed ? 0 : MarkdownReveal.blurRadius)
            .offset(y: revealed ? 0 : MarkdownReveal.yOffset)
            .animation(animation, value: revealed)
    }
}

extension View {
    /// Applies the shared CustomMarkdown fade (blur + float + opacity),
    /// staggered by `index` within the parent block.
    func markdownReveal(
        _ revealed: Bool,
        index: Int = 0,
        unitDelay: Double = MarkdownReveal.unitDelay,
        startDelay: Double = MarkdownReveal.startDelay
    ) -> some View {
        modifier(
            MarkdownRevealModifier(
                revealed: revealed,
                animation: MarkdownReveal.animation(
                    index: index,
                    unitDelay: unitDelay,
                    startDelay: startDelay
                )
            )
        )
    }
}

import SwiftUI

/// Full-document markdown renderer built on the custom parser
/// (`StableMarkdownParser`) + `CustomMarkdownBlock`. This is the static
/// (non-streaming) counterpart to the chat path: it parses the whole string
/// once and renders each block through the same CustomMarkdown views, so file
/// previews and inspector surfaces share one renderer with the chat.
public struct CustomMarkdownView: View {
  public let content: String
  public var style: MarkdownStyle
  public var theme: MarkdownTheme
  /// Optional link interception (repo-relative file links, in-app browser).
  /// When nil, links use the default system/open-URL behavior.
  public var onLinkTap: ((URL) -> OpenURLAction.Result)?

  public init(
    content: String,
    style: MarkdownStyle = .chat,
    theme: MarkdownTheme = .standard,
    onLinkTap: ((URL) -> OpenURLAction.Result)? = nil
  ) {
    self.content = content
    self.style = style
    self.theme = theme
    self.onLinkTap = onLinkTap
  }

  @State private var parser = StableMarkdownParser()

  public var body: some View {
    LazyVStack(alignment: .leading, spacing: 0) {
      ForEach(parser.blocks) { block in
        CustomMarkdownBlock(block: block.content, style: style, theme: theme)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .modifier(LinkTapOverride(onLinkTap: onLinkTap))
    .onChange(of: content, initial: true) { _, newValue in
      parser.update(markdown: newValue)
    }
  }
}

// MARK: - Link Override

private struct LinkTapOverride: ViewModifier {
  let onLinkTap: ((URL) -> OpenURLAction.Result)?

  func body(content: Content) -> some View {
    if let onLinkTap {
      content.environment(\.openURL, OpenURLAction { url in onLinkTap(url) })
    } else {
      content
    }
  }
}

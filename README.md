# `@jerrick/swift-markdown`

Native SwiftUI Markdown rendering for static documents and append-only streaming
content. The package includes selectable text, fenced code highlighting, unified
diffs, tables, math, lists, block quotes, links, and supported HTML blocks.

- Swift product and module: `JerrickMarkdown`
- Platform: iOS 17 or newer
- External packages: `SwiftUIMath` and `Highlightr`
- Runtime resources: bundled highlight.js and file-type SVG assets

## Install from npm

npm distributes the complete Swift package source, including `Package.swift`
and its runtime resources:

```bash
npm install @jerrick/swift-markdown
```

In Xcode, choose **Add Local Package**, select
`node_modules/@jerrick/swift-markdown`, and link the `JerrickMarkdown` product
to the application target. Another Swift package can use the installed path:

```swift
dependencies: [
  .package(path: "node_modules/@jerrick/swift-markdown")
],
targets: [
  .target(
    name: "YourApp",
    dependencies: [
      .product(name: "JerrickMarkdown", package: "swift-markdown")
    ]
  )
]
```

The path is relative to the consuming `Package.swift`. npm is the remote source
transport; Xcode and Swift Package Manager still resolve and build the Swift
dependencies declared by the installed manifest.

## Install from a local checkout

Select `packages/swift-markdown` as a local Swift package in Xcode, or use a
relative path from another package:

```swift
dependencies: [
  .package(path: "../swift-markdown")
],
targets: [
  .target(
    name: "YourApp",
    dependencies: [
      .product(name: "JerrickMarkdown", package: "swift-markdown")
    ]
  )
]
```

Direct `.package(url:)` installation requires a dedicated Git repository whose
root contains this manifest and whose versions are Git tags. The `@jerrick`
monorepo does not have that shape, so use the npm install above until a dedicated
Swift registry or repository is published.

## Render a Markdown document

`CustomMarkdownView` is the full-document renderer:

```swift
import JerrickMarkdown
import SwiftUI

struct ArticleView: View {
  let markdown: String

  var body: some View {
    ScrollView {
      CustomMarkdownView(content: markdown)
        .padding()
    }
  }
}
```

Use the compact reasoning preset when a surface needs smaller typography:

```swift
CustomMarkdownView(
  content: markdown,
  style: .reasoning
)
```

## Render append-only streaming Markdown

The package accepts the complete accumulated Markdown string. Transport,
deltas, persistence, and stream lifecycle remain application concerns.

```swift
import JerrickMarkdown
import SwiftUI

struct StreamingReplyView: View {
  let accumulatedMarkdown: String
  let isStreaming: Bool

  @State private var parser = StableMarkdownParser()

  var body: some View {
    let tailID = isStreaming ? parser.blocks.last?.id : nil

    LazyVStack(alignment: .leading, spacing: 0) {
      ForEach(parser.blocks) { block in
        CustomMarkdownBlock(
          block: block.content,
          style: .chat,
          isStreamingTail: tailID == block.id
        )
      }
    }
    .onChange(of: accumulatedMarkdown, initial: true) { _, markdown in
      parser.update(markdown: markdown)
    }
  }
}
```

`StableMarkdownParser` preserves the identity of settled blocks and reparses
only the mutable tail when the stable prefix is unchanged. Pass
`isStreamingTail: true` only for the current final block so incomplete inline
syntax and word-reveal behavior stay localized to that block.

## Render a code block

```swift
CodeBlock(
  code: """
  struct Greeting {
    let message = "Hello"
  }
  """,
  language: "swift",
  animated: false
)
```

`language` is the fenced-code hint. When it is omitted, the renderer uses its
built-in content heuristics. Set `animated` to `false`
for historical or reusable content that should not reveal again on appearance.

## Render a unified diff

The package owns the display model `MarkdownDiffLine`; parsing a repository or
provider-specific diff remains outside the package.

```swift
let lines: [MarkdownDiffLine] = [
  .init(
    kind: .hunk,
    content: "@@ -1,2 +1,2 @@"
  ),
  .init(
    kind: .deletion,
    content: "let title = \"Old\"",
    oldLineNumber: 1
  ),
  .init(
    kind: .addition,
    content: "let title = \"New\"",
    newLineNumber: 1
  ),
  .init(
    kind: .context,
    content: "render(title)",
    oldLineNumber: 2,
    newLineNumber: 2
  )
]

CodeBlock(
  language: "swift",
  animated: false,
  diffLines: lines,
  fileName: "TitleView.swift"
)
```

If an application already has a domain diff type, map it to
`MarkdownDiffLine` once at the UI boundary. This keeps repository parsing out
of the renderer and preserves stable row identifiers.

## Fetch and render Markdown

`FetchedMarkdownView` loads raw Markdown over HTTP, accepts only a 2xx response,
and supplies package-owned loading, error, and retry UI:

```swift
FetchedMarkdownView(
  url: URL(string: "https://example.com/guide.md")!,
  onLinkTap: { url in
    openInsideApp(url)
    return .handled
  },
  onLoad: { markdown in
    cache(markdown)
  }
)
```

When `onLinkTap` is omitted, SwiftUI's normal `openURL` behavior handles links.
Return `.systemAction` from the callback to hand a link back to the system.

## Theme colors

Every package-owned surface reads from `MarkdownTheme`: code chrome, tables,
diffs, fetched-document errors, separators, and file-type icons. The default
compatibility theme preserves the existing light and dark values.

Reuse one theme instance instead of constructing it inside `body`.
`MarkdownTheme` is immutable and identity-equatable, so a long-lived instance
keeps theme propagation out of the streaming update path.

```swift
import JerrickMarkdown
import SwiftUI

private enum AppMarkdownTheme {
  static let value: MarkdownTheme = {
    let base = MarkdownTheme.standard

    return MarkdownTheme(
      separator: base.separator,
      code: .init(
        headerBackground: .init(
          light: Color(red: 0.94, green: 0.95, blue: 0.97),
          dark: Color(red: 0.08, green: 0.09, blue: 0.11)
        ),
        bodyBackground: base.code.bodyBackground,
        label: base.code.label,
        actionForeground: base.code.actionForeground,
        actionBackground: base.code.actionBackground,
        copiedForeground: base.code.copiedForeground
      ),
      table: base.table,
      diff: base.diff,
      fetch: base.fetch,
      fileIcon: base.fileIcon
    )
  }()
}

CustomMarkdownView(
  content: markdown,
  theme: AppMarkdownTheme.value
)
```

Typography and spacing are separate from color tokens and use
`MarkdownStyle`. Start from `.chat` or `.reasoning`, then modify the value:

```swift
private let documentStyle: MarkdownStyle = {
  var style = MarkdownStyle.chat
  style.baseSize = 17
  style.blockBottomPadding = 18
  return style
}()

CustomMarkdownView(
  content: markdown,
  style: documentStyle,
  theme: AppMarkdownTheme.value
)
```

The bundled file icon can also be used directly:

```swift
FileTypeIconView(
  ext: "swift",
  size: 18,
  theme: AppMarkdownTheme.value
)
```

## Supported content and boundaries

The renderer supports:

- headings, paragraphs, emphasis, strong text, strike-through, inline code,
  links, and common inline HTML formatting;
- fenced code blocks with language detection and syntax highlighting;
- ordered and unordered lists, block quotes, thematic breaks, and tables;
- `$$` display math through `SwiftUIMath`;
- HTML tables, code blocks, block quotes, paragraphs, headings, and
  `<details>`/`<summary>`; and
- selectable settled prose and code with append-only streaming word reveals.

Images and `<picture>` blocks are deliberately skipped; the package does not
own image fetching. It also does not own navigation sheets, repository link
resolution, logging, stream transport, persistence, or application diff
parsing.

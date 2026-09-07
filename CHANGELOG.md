# Changelog

## Unreleased

- Tables no longer clip their header and last rows. A table whose columns fit
  the container lays out at the container width and wraps long cells; wider
  tables scroll horizontally. `SelectableMarkdownText` now answers SwiftUI's
  ideal-size probe with its unwrapped size so measured and rendered heights
  agree.
- Table cells are UIKit-backed `SelectableMarkdownText`, giving them the same
  grabber-handle selection as prose.
- Native synchronous syntax highlighter (`NativeSyntaxHighlighter`) replaces
  Highlightr and the bundled highlight.js: colors land with the text on the
  first frame, results are cached above the view tree, and blocks repaint on
  foreground. The `Highlightr` dependency and `highlight.min.js` resource are
  removed. A bare ``` fence renders plain instead of guessing a language.
- Streaming parser folds appended bytes into the open block for paragraphs,
  lists, tables, block quotes, fenced code, and `<details>` bodies instead of
  re-parsing the whole tail on every flush.
- Streaming parser fast paths: incremental tail-line reuse for append-only
  updates, plain-paragraph and list-item append tracking, and byte-based stable
  offsets so a long response no longer re-splits its tail on every flush.
- Inline parser fast paths: ASCII whitespace/punctuation classification, UTF-8
  scans instead of `Character` scans, and buffer capacity reservation.
- Cheap rejects before expensive work: table promotion bails on non-`|` prose,
  and the empty-tail check bounds the committed prefix before copying it.

## 0.1.0 — 2026-08-10

- Initial standalone Swift Package Manager distribution of `JerrickMarkdown`.
- Includes static and append-only streaming Markdown, code and diff rendering,
  tables, math, supported HTML, selectable text, and theme customization.
- Requires iOS 17 or newer and Swift tools 6.0.

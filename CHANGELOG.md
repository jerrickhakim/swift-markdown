# Changelog

## Unreleased

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

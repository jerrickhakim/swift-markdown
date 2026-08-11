# `@jerrick/swift-markdown`

This package owns the native iOS counterpart to `@jerrick/markdown`: static and
append-only streaming Markdown rendering, syntax-highlighted code, unified
diffs, tables, math, supported HTML blocks, and token-driven SwiftUI surfaces.

## Boundaries

- Keep transport, chat state, persistence, navigation, and repository-specific
  diff parsing in the consuming application.
- Public APIs must remain usable after `import JerrickMarkdown`; do not depend
  on helpers from a host application.
- The minimum platform is iOS 17. Preserve light and dark appearance and
  selectable text behavior.
- Runtime assets belong under `Sources/JerrickMarkdown/Resources`. Record the
  license of every bundled third-party asset in `THIRD_PARTY_NOTICES.md`.
- npm is a source transport. SwiftPM still resolves `Package.swift` after the
  package is installed into `node_modules`.

Verify changes with:

```bash
bun run check:ios
```

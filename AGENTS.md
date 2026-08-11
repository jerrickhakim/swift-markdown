# JerrickMarkdown

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
- Distribute releases through Swift Package Manager using semantic Git tags.

Verify changes with:

```sh
xcodebuild -scheme swift-markdown -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO -quiet build
```

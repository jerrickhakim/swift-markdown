//
//  MarkdownParserSafetyTests.swift
//  repogoTests
//
//  Safety net for the streaming markdown pipeline. The renderer parses on the
//  MAIN THREAD on every stream delta, so a parser that fails to make forward
//  progress doesn't just misrender — it freezes the UI and the app gets
//  watchdog-killed (reads to the user as a crash). This is exactly what a line
//  like "#1 applied." used to do: a `#` not followed by a space isn't a valid
//  heading, fell through to the paragraph parser, which broke on the `#` prefix
//  without consuming the line, and spun `parse()` forever.
//
//  These tests assert the two properties that keep that from ever shipping again:
//    1. TERMINATION — every input (and every streaming prefix of it) parses
//       within a tight time budget. A hang fails the test instead of the app.
//    2. NO CRASH — adversarial input doesn't trap (out-of-bounds, force-unwrap,
//       unbounded recursion). A crash here fails the whole test run.
//
//  When you touch the parser, add any input that broke it to `regressionCorpus`.
//

import XCTest

@testable import JerrickMarkdown

final class MarkdownParserSafetyTests: XCTestCase {

  // MARK: - Termination helper

  /// Runs `work` off the test thread and fails if it doesn't finish in time.
  /// A genuine infinite loop would otherwise hang the whole test runner; here it
  /// surfaces as a clean failure (the spun thread is abandoned when the process
  /// exits — acceptable for a test target).
  private func assertCompletes(
    within seconds: TimeInterval = 2,
    _ label: String,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ work: @escaping () -> Void
  ) {
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInitiated).async {
      work()
      done.signal()
    }
    if done.wait(timeout: .now() + seconds) == .timedOut {
      XCTFail(
        "Parse did not terminate within \(seconds)s — likely an infinite loop: \(label)",
        file: file, line: line)
    }
  }

  /// Parse `text` and every one of its prefixes, the way the streaming renderer
  /// feeds the parser one delta at a time. This is the shape that surfaces
  /// forward-progress bugs — the full text can be clean while some prefix hangs.
  private func parseAllPrefixes(_ text: String) {
    let chars = Array(text)
    guard !chars.isEmpty else { return }
    for len in 1...chars.count {
      _ = MarkdownParser.parse(String(chars[0..<len]))
    }
  }

  /// Drive the incremental parser exactly like the live path (`StableMarkdownParser`
  /// keeps state across deltas and re-parses only the tail).
  private func streamThroughStableParser(_ text: String) {
    let parser = StableMarkdownParser()
    let chars = Array(text)
    guard !chars.isEmpty else { return }
    // Step by a few chars per delta to keep it quick while still exercising
    // every block boundary the tail logic cares about.
    var len = 1
    while len <= chars.count {
      parser.update(markdown: String(chars[0..<len]))
      len += 3
    }
    parser.update(markdown: text)
  }

  // MARK: - Corpora

  /// Inputs that have broken the parser before, or are one keystroke away from
  /// the failure modes. Each must parse instantly. ADD TO THIS when you find a
  /// new break.
  private static let regressionCorpus: [String] = [
    "#1 applied.",                       // the original hang: `#` + non-space
    "#1 applied. (note about SourceKit)",
    "prose first\n\n#1 applied.\n\nmore prose",
    "#foo",
    "##bar",
    "####### seven hashes is not a heading",
    "#!/bin/bash",                       // shebang at line start
    "#include <stdio.h>",                // C preprocessor in prose
    "#",                                 // bare hash (valid empty heading)
    "###### h6",
    "1.",                                // bare ordered marker
    "1. item\n2. item\n3. item",
    "- a\n\n- b\n\n- c",                 // loose list
    "> quote\n> more",
    "| a | b |\n| - | - |\n| 1 | 2 |",   // table
    "```swift\nlet x = 1",               // unterminated code fence
    "$$\n\\frac{1}{2}",                  // unterminated math fence
    "**bold** and *em* and `code` and ~~strike~~",
  ]

  // MARK: - Termination

  func testRegressionCorpusTerminates() {
    for input in Self.regressionCorpus {
      assertCompletes(within: 1, "regression: \(input.prefix(40))") {
        _ = MarkdownParser.parse(input)
      }
    }
  }

  func testRegressionCorpusStreamsWithoutHang() {
    for input in Self.regressionCorpus {
      assertCompletes(within: 2, "streaming prefixes: \(input.prefix(40))") {
        self.parseAllPrefixes(input)
      }
      assertCompletes(within: 2, "stable parser: \(input.prefix(40))") {
        self.streamThroughStableParser(input)
      }
    }
  }

  /// A long, realistic assistant message (headings, ordered/loose lists, inline
  /// code, the `#N` references that started this) streamed delta-by-delta.
  func testRealisticMessageStreamsWithoutHang() {
    let message = """
      ## What's already optimized

      - **Incremental parse with a stable-prefix cache** — only the trailing block re-parses per delta.
      - **Per-block isolation** — only the changed block re-renders.

      ## Where cost remains

      1. **`trimmedCode` recomputed ~3×/delta** — `CodeBlock.swift:155`, a full O(n) copy. *Safe fix.*
      2. **`.task(id:)` compares the full string** — O(n) per delta.
      3. **`jobKey` hashes the code on the main actor** — O(n).

      #1 applied. (The `No such module 'UIKit'` diagnostic is just SourceKit.)

      ## On #4 — I'd skip it

      When I went to implement it I traced exactly *when* the double-parse fires.
      """
    assertCompletes(within: 3, "realistic message prefixes") {
      self.parseAllPrefixes(message)
    }
    assertCompletes(within: 3, "realistic message stable parser") {
      self.streamThroughStableParser(message)
    }
  }

  // MARK: - No crash on adversarial input

  func testAdversarialInputsDoNotHangOrCrash() {
    let inputs: [String] = [
      // Deep bracket nesting / matcher stress — must not hang or crash. (The
      // parser bounds link recursion via `linksEnabled: false` inside link text,
      // so these render as literal text; this locks that no-deep-recursion
      // property so a future change can't silently reintroduce a stack overflow.)
      String(repeating: "[", count: 20000) + "x" + String(repeating: "]", count: 20000),
      String(repeating: "[", count: 20000) + "x" + String(repeating: "](u)", count: 20000),
      // Long alternating emphasis runs — stresses the delimiter matcher.
      String(repeating: "* x ", count: 5000),
      String(repeating: "_a_ ", count: 5000),
      String(repeating: "~~s~~ ", count: 3000),
      // Many invalid-heading lines (each was a potential hang).
      (1...1000).map { "#\($0) item" }.joined(separator: "\n"),
      // Unbalanced / unterminated structures.
      String(repeating: "`", count: 4000),
      String(repeating: "#", count: 4000),
      String(repeating: ">", count: 4000),
      "```\n" + String(repeating: "code line\n", count: 5000),
      // Pipe/dash soup that flirts with the table grammar.
      String(repeating: "| - ", count: 3000),
    ]
    for (i, input) in inputs.enumerated() {
      assertCompletes(within: 4, "adversarial[\(i)] (len \(input.count))") {
        _ = MarkdownParser.parse(input)
        _ = InlineMarkdown.traitRuns(input, isTail: true)
      }
    }
  }

  /// Deterministic pseudo-random soup of markdown-significant characters, parsed
  /// both whole and as a stream. Catches forward-progress and bounds bugs that a
  /// fixed corpus misses. Seeded so failures reproduce.
  func testRandomizedFuzzTerminates() {
    let alphabet = Array("#*_`~[]()<>|-+. \n\t!\\$abc123")
    var state: UInt64 = 0x9E37_79B9_7F4A_7C15
    func next() -> UInt64 {  // xorshift64 — no Date/Random dependency
      state ^= state << 13
      state ^= state >> 7
      state ^= state << 17
      return state
    }
    assertCompletes(within: 8, "randomized fuzz (300 cases)") {
      for _ in 0..<300 {
        let length = Int(next() % 300) + 1
        var s = ""
        s.reserveCapacity(length)
        for _ in 0..<length {
          s.append(alphabet[Int(next() % UInt64(alphabet.count))])
        }
        _ = MarkdownParser.parse(s)
        _ = InlineMarkdown.traitRuns(s, isTail: true)
        _ = InlineMarkdown.traitRuns(s, isTail: false)
        // Stream a subset (every prefix is O(n²); cap to keep the suite fast).
        if s.count <= 80 { self.parseAllPrefixes(s) }
      }
    }
  }

  // MARK: - Correctness guards (so a "fix" can't over-correct)

  /// The exact regression: a `#`-prefixed line that isn't a valid heading must
  /// render as a paragraph (CommonMark), not vanish and not loop.
  func testNonHeadingHashLineBecomesParagraph() {
    let blocks = MarkdownParser.parse("#1 applied. (note)")
    XCTAssertEqual(blocks.count, 1)
    XCTAssertEqual(blocks.first?.type, "paragraph")
    if case .paragraph(let text, _) = blocks.first {
      XCTAssertEqual(text, "#1 applied. (note)")
    } else {
      XCTFail("expected a paragraph block")
    }
  }

  /// Valid ATX headings (# … ######, including a bare #) must still be headings —
  /// the forward-progress fix must not have demoted them.
  func testValidHeadingsStillParseAsHeadings() {
    for (input, level) in [("# H1", 1), ("## H2", 2), ("###### H6", 6), ("#", 1)] {
      let blocks = MarkdownParser.parse(input)
      XCTAssertEqual(blocks.first?.type, "heading", "expected heading for \"\(input)\"")
      if case .heading(let parsedLevel, _, _) = blocks.first {
        XCTAssertEqual(parsedLevel, level, "wrong level for \"\(input)\"")
      }
    }
  }

  /// 7+ hashes is not a heading in CommonMark — it's a paragraph (and used to hang).
  func testSevenHashesIsParagraph() {
    let blocks = MarkdownParser.parse("####### too many")
    XCTAssertEqual(blocks.first?.type, "paragraph")
  }
}

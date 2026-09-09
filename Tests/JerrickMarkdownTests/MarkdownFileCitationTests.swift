import XCTest
@testable import JerrickMarkdown

final class MarkdownFileCitationTests: XCTestCase {
  private let citation = ":codex-file-citation{path=\"/work/report 100%.pdf\" purpose=\"output\"}"

  func testCitationBecomesInlineFileLink() {
    let runs = InlineMarkdown.traitRuns("Created " + citation + " today.")
    XCTAssertEqual(runs.map(\.text).joined(), "Created 📄 report 100%.pdf today.")
    let link = runs.first(where: \.isLink)
    XCTAssertEqual(link?.linkDestination, URL(fileURLWithPath: "/work/report 100%.pdf").absoluteString)
  }

  func testCodeAndEscapesRemainLiteral() {
    let code = InlineMarkdown.traitRuns("`" + citation + "`")
    XCTAssertEqual(code.map(\.text).joined(), citation)
    XCTAssertTrue(code.allSatisfy { !$0.isLink && $0.code })
    XCTAssertFalse(InlineMarkdown.traitRuns("\\" + citation).contains(where: \.isLink))
  }

  func testMalformedCitationsStayLiteral() {
    for text in [":codex-file-citation{purpose=\"output\"}",
                 ":codex-file-citation{path=\"\"}",
                 ":codex-file-citation{path=\"a.pdf\" path=\"b.pdf\"}"] {
      let runs = InlineMarkdown.traitRuns(text)
      XCTAssertEqual(runs.map(\.text).joined(), text)
      XCTAssertFalse(runs.contains(where: \.isLink))
    }
  }

  func testStreamingPrefixesNeverActivatePartialPath() {
    var prefix = ""
    for character in citation.dropLast() {
      prefix.append(character)
      XCTAssertFalse(InlineMarkdown.traitRuns(prefix, isTail: true).contains(where: \.isLink))
    }
    XCTAssertTrue(InlineMarkdown.traitRuns(citation, isTail: true).contains(where: \.isLink))
  }
}

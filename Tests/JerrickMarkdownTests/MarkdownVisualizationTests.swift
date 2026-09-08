import XCTest
@testable import JerrickMarkdown

final class MarkdownVisualizationTests: XCTestCase {
  private let marker = "visualize{\"path\":\"/workspace/preview.html\",\"title\":\"Example\",\"mode\":\"wide\"}"

  func testReferenceDecoding() {
    let blocks = MarkdownParser.parse(marker)
    guard case .visualization(let reference?, let source) = blocks.first else {
      return XCTFail("Expected a visualization")
    }
    XCTAssertEqual(reference.path, "/workspace/preview.html")
    XCTAssertEqual(reference.title, "Example")
    XCTAssertEqual(reference.mode, "wide")
    XCTAssertEqual(source, marker)
  }

  func testEveryStreamingPrefixMatchesFullParse() {
    for text in [marker, "Before\n" + marker + "\nAfter", "Before\n\n" + marker + "\n\nAfter"] {
      let parser = StableMarkdownParser()
      var prefix = ""
      for character in text {
        prefix.append(character)
        parser.updateAppending(markdown: prefix)
        XCTAssertEqual(parser.blocks.map(\.content), MarkdownParser.parse(prefix), prefix)
      }
      XCTAssertEqual(parser.blocks.count, text == marker ? 1 : 3)
    }
  }

  func testIncompleteReferenceRetainsSource() {
    let partial = "visualize{\"path\":"
    XCTAssertEqual(MarkdownParser.parse(partial), [.visualization(reference: nil, source: partial)])
  }

  func testCodeAndInvalidReferencesRemainLiteral() {
    XCTAssertEqual(MarkdownParser.parse("```text\n" + marker + "\n```"),
                   [.codeBlock(language: "text", code: marker)])
    for text in ["visualize{}", "visualizebad json", "unknown{}",
                 "visualize{\"path\":\"\"}", "Example: " + marker] {
      XCTAssertEqual(MarkdownParser.parse(text), [.paragraph(text: text, alignment: .leading)])
    }
  }

  func testSettledPreviewKeepsIdentityAsProseArrives() {
    let parser = StableMarkdownParser()
    parser.updateAppending(markdown: marker + "\n\nAfter")
    let id = parser.blocks.first?.id
    parser.updateAppending(markdown: marker + "\n\nAfter more text")
    XCTAssertEqual(parser.blocks.first?.id, id)
  }

  func testDocumentEscapesFragmentInsideSandboxAttribute() throws {
    let document = try VisualizationDocument.wrap("<p title=\"test\">&</p>")
    XCTAssertTrue(document.contains("sandbox=\"allow-scripts\""))
    XCTAssertTrue(document.contains("&lt;p title=&quot;test&quot;&gt;&amp;&lt;/p&gt;"))
    XCTAssertTrue(document.contains("connect-src 'none'"))
    XCTAssertFalse(document.contains("allow-same-origin"))
  }

  func testOpaqueDocumentURLsAreAllowedWithoutOpeningOtherNavigation() {
    for text in ["about:blank", "about:srcdoc"] {
      XCTAssertTrue(VisualizationDocument.isInternalURL(URL(string: text)), text)
    }
    for text in ["https://example.com", "file:///preview.html", "data:text/html,test",
                 "about:blank/other", "about:srcdoc?other", "repogo://workspaces"] {
      XCTAssertFalse(VisualizationDocument.isInternalURL(URL(string: text)), text)
    }
    XCTAssertFalse(VisualizationDocument.isInternalURL(nil))
  }
}

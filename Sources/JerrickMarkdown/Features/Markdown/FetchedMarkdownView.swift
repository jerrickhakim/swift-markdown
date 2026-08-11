import SwiftUI

/// Renders markdown fetched over HTTP through the package renderer.
///
/// ```swift
/// FetchedMarkdownView(url: URL(string: "https://example.com/docs/start.md")!)
/// ```
public struct FetchedMarkdownView: View {
  public let url: URL
  public var style: MarkdownStyle
  public var theme: MarkdownTheme
  /// Link interception, forwarded to the renderer. When nil, links use the
  /// default open-URL behavior.
  public var onLinkTap: ((URL) -> OpenURLAction.Result)?
  /// The fetched markdown, for surfaces that act on the raw text (copy, share).
  public var onLoad: ((String) -> Void)?

  public init(
    url: URL,
    style: MarkdownStyle = .chat,
    theme: MarkdownTheme = .standard,
    onLinkTap: ((URL) -> OpenURLAction.Result)? = nil,
    onLoad: ((String) -> Void)? = nil
  ) {
    self.url = url
    self.style = style
    self.theme = theme
    self.onLinkTap = onLinkTap
    self.onLoad = onLoad
  }

  @State private var content: String?
  @State private var failure: String?
  /// Bumped by Retry to re-run the load task.
  @State private var attempt = 0

  public var body: some View {
    Group {
      if let content {
        CustomMarkdownView(content: content, style: style, theme: theme, onLinkTap: onLinkTap)
      } else if let failure {
        errorState(failure)
      } else {
        ProgressView()
          .frame(maxWidth: .infinity)
          .padding(.vertical, 40)
      }
    }
    .task(id: TaskKey(url: url, attempt: attempt)) { await load() }
  }

  // MARK: - Sub-views

  private func errorState(_ message: String) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      MarkdownFetchErrorMessage(message: message, theme: theme)
      MarkdownRetryButton(theme: theme) { attempt += 1 }
    }
    .padding(.vertical, 24)
  }

  // MARK: - Loading

  private func load() async {
    content = nil
    failure = nil

    do {
      let (data, response) = try await URLSession.shared.data(from: url)
      guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
        throw URLError(.badServerResponse)
      }
      let markdown = String(decoding: data, as: UTF8.self)
      content = markdown
      onLoad?(markdown)
    } catch let error as URLError where error.code == .cancelled {
      // View went away mid-flight; leave the placeholder.
    } catch {
      failure = error.localizedDescription
    }
  }
}

private struct TaskKey: Equatable {
  let url: URL
  let attempt: Int
}

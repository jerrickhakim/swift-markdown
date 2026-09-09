import SwiftUI
import WebKit

private struct VisualizationLoader {
  let id: AnyHashable
  let load: @MainActor (String) async throws -> String
}

private struct VisualizationLoaderKey: EnvironmentKey {
  static let defaultValue: VisualizationLoader? = nil
}

private struct VisualizationCardFillKey: EnvironmentKey {
  static let defaultValue: Color = Color.primary.opacity(0.08)
}

extension View {
  public func markdownVisualizationCardFill(_ color: Color) -> some View {
    environment(\.visualizationCardFill, color)
  }

  /// Use a stable identity for the file source so switching workspaces reloads previews.
  public func markdownVisualizationLoader(
    id: AnyHashable,
    load: @escaping @MainActor (String) async throws -> String
  ) -> some View {
    environment(\.visualizationLoader, VisualizationLoader(id: id, load: load))
  }
}

private extension EnvironmentValues {
  var visualizationCardFill: Color {
    get { self[VisualizationCardFillKey.self] }
    set { self[VisualizationCardFillKey.self] = newValue }
  }

  var visualizationLoader: VisualizationLoader? {
    get { self[VisualizationLoaderKey.self] }
    set { self[VisualizationLoaderKey.self] = newValue }
  }
}

struct MarkdownVisualizationView: View {
  let reference: MarkdownVisualizationReference
  @Environment(\.visualizationLoader) private var loader
  @Environment(\.visualizationCardFill) private var cardFill
  @StateObject private var session = VisualizationSession()
  @State private var expanded = false
  @State private var inlineExpanded = false
  @State private var retry = 0

  private struct LoadID: Hashable {
    let source: AnyHashable?
    let path: String
    let retry: Int
    let wide: Bool
  }

  private var title: String {
    let title = reference.title?.trimmingCharacters(in: .whitespacesAndNewlines)
    return title.flatMap { $0.isEmpty ? nil : $0 } ?? "Preview"
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 0) {
        Button { expanded = true } label: {
          HStack(spacing: 12) {
            Text(title)
              .font(.subheadline.weight(.medium))
              .lineLimit(2)
              .multilineTextAlignment(.leading)
            Spacer(minLength: 12)
            Image(systemName: "globe")
              .font(.system(size: 32, weight: .light))
              .rotationEffect(.degrees(29))
              .offset(x: 3, y: 3)
              .accessibilityHidden(true)
          }
          .foregroundStyle(.primary)
          .padding(16)
          .frame(maxWidth: .infinity, minHeight: 64)
          .contentShape(Rectangle())
        }
        .accessibilityHint("Opens preview sheet")

        Button { inlineExpanded.toggle() } label: {
          Image(systemName: inlineExpanded ? "chevron.up" : "chevron.down")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 48, height: 64)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(inlineExpanded ? "Collapse preview" : "Expand preview inline")
      }
      .buttonStyle(.plain)
      .background(cardFill, in: RoundedRectangle(cornerRadius: 16))

      if inlineExpanded {
        Group {
          if expanded {
            Color.clear
          } else {
            previewContent
          }
        }
        .frame(height: min(480, max(80, session.height)))
        .padding(.top, 8)
      }
    }
    .task(id: LoadID(source: loader?.id, path: reference.path, retry: retry, wide: reference.mode == "wide")) {
      await session.load(path: reference.path, wide: reference.mode == "wide", loader: loader)
    }
    .sheet(isPresented: $expanded) {
      NavigationStack {
        previewContent
          .navigationTitle(title)
          .navigationBarTitleDisplayMode(.inline)
          .toolbar {
            ToolbarItem(placement: .topBarLeading) {
              Button { expanded = false } label: {
                Image(systemName: "xmark")
              }
              .accessibilityLabel("Close preview")
            }
          }
      }
    }
  }

  @ViewBuilder
  private var previewContent: some View {
    if session.ready {
      VisualizationWebView(session: session)
    } else if session.loading {
      ProgressView("Loading preview…")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      VStack(spacing: 12) {
        Text(session.message ?? "Preview unavailable")
          .foregroundStyle(.secondary)
        if loader != nil && !session.empty {
          Button("Retry") { retry += 1 }
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}

@MainActor
private final class VisualizationSession: NSObject, ObservableObject, WKScriptMessageHandler,
  WKNavigationDelegate {
  @Published var height: CGFloat = 240
  @Published var loading = false
  @Published var ready = false
  @Published var empty = false
  @Published var message: String?
  private(set) var webView: WKWebView?

  func load(path: String, wide: Bool, loader: VisualizationLoader?) async {
    reset()
    guard let loader else {
      message = "Preview unavailable"
      return
    }
    loading = true
    do {
      let html = try await loader.load(path)
      try Task.checkCancellation()
      guard html.utf8.count <= 1_048_576 else {
        loading = false
        message = "Preview unavailable"
        return
      }
      if html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        loading = false
        empty = true
        message = "Preview is empty"
        return
      }
      let configuration = WKWebViewConfiguration()
      configuration.websiteDataStore = .nonPersistent()
      configuration.userContentController.add(VisualizationMessageRelay(self), name: "previewHeight")
      let view = WKWebView(frame: .zero, configuration: configuration)
      view.navigationDelegate = self
      view.isOpaque = false
      view.backgroundColor = .clear
      view.scrollView.backgroundColor = .clear
      webView = view
      view.loadHTMLString(try VisualizationDocument.wrap(html, wide: wide), baseURL: nil)
    } catch is CancellationError {
      // A replacement task owns the next state.
    } catch {
      guard !Task.isCancelled else { return }
      loading = false
      message = "Preview unavailable"
    }
  }

  private func reset() {
    webView?.stopLoading()
    webView?.navigationDelegate = nil
    webView?.configuration.userContentController.removeScriptMessageHandler(forName: "previewHeight")
    webView = nil
    loading = false
    ready = false
    empty = false
    message = nil
    height = 240
  }

  func userContentController(_ userContentController: WKUserContentController,
                            didReceive message: WKScriptMessage) {
    guard message.frameInfo.isMainFrame, let value = message.body as? Double,
          value.isFinite else { return }
    let next = CGFloat(min(10_000, max(80, value)))
    if abs(next - height) > 1 { height = next }
  }

  func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
               decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    let allowed = navigationAction.navigationType == .other
      && VisualizationDocument.isInternalURL(navigationAction.request.url)
    decisionHandler(allowed ? .allow : .cancel)
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    guard webView === self.webView else { return }
    ready = true
    loading = false
  }

  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
               withError error: Error) {
    failed(webView)
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    failed(webView)
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    failed(webView)
  }

  private func failed(_ view: WKWebView) {
    guard view === webView else { return }
    ready = false
    loading = false
    message = "Preview unavailable"
  }
}

@MainActor
private final class VisualizationMessageRelay: NSObject, WKScriptMessageHandler {
  weak var session: VisualizationSession?

  init(_ session: VisualizationSession) { self.session = session }

  func userContentController(_ userContentController: WKUserContentController,
                            didReceive message: WKScriptMessage) {
    session?.userContentController(userContentController, didReceive: message)
  }
}

private struct VisualizationWebView: UIViewRepresentable {
  let session: VisualizationSession

  func makeUIView(context: Context) -> UIView { UIView() }

  func updateUIView(_ container: UIView, context: Context) {
    guard let webView = session.webView, webView.superview !== container else { return }
    container.subviews.forEach { $0.removeFromSuperview() }
    webView.removeFromSuperview()
    webView.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(webView)
    NSLayoutConstraint.activate([
      webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      webView.topAnchor.constraint(equalTo: container.topAnchor),
      webView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
    ])
  }
}

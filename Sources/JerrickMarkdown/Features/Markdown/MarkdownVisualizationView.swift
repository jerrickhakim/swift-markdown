import SwiftUI
import WebKit

private struct VisualizationLoader {
  let id: AnyHashable
  let load: @MainActor (String) async throws -> String
}

private struct VisualizationLoaderKey: EnvironmentKey {
  static let defaultValue: VisualizationLoader? = nil
}

private struct VisualizationScopeKey: EnvironmentKey {
  static let defaultValue: AnyView? = nil
}

extension View {
  /// Use a stable identity for the file source so switching workspaces reloads previews.
  public func markdownVisualizationLoader(
    id: AnyHashable,
    load: @escaping @MainActor (String) async throws -> String
  ) -> some View {
    environment(\.visualizationLoader, VisualizationLoader(id: id, load: load))
  }

  public func markdownVisualizationScope<Scope: View>(
    @ViewBuilder _ scope: () -> Scope
  ) -> some View {
    environment(\.visualizationScope, AnyView(scope()))
  }
}

private extension EnvironmentValues {
  var visualizationLoader: VisualizationLoader? {
    get { self[VisualizationLoaderKey.self] }
    set { self[VisualizationLoaderKey.self] = newValue }
  }

  var visualizationScope: AnyView? {
    get { self[VisualizationScopeKey.self] }
    set { self[VisualizationScopeKey.self] = newValue }
  }
}

struct MarkdownVisualizationView: View {
  let reference: MarkdownVisualizationReference
  @Environment(\.visualizationLoader) private var loader
  @Environment(\.visualizationScope) private var scope
  @StateObject private var session = VisualizationSession()
  @State private var expanded = false
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
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(title).font(.subheadline.weight(.medium)).lineLimit(1)
        Spacer()
        if session.ready {
          Button("Expand") { expanded = true }
            .font(.subheadline)
        } else if session.loading {
          ProgressView()
        }
      }
      if session.ready {
        Group {
          if expanded {
            Color.clear
          } else {
            VisualizationWebView(session: session)
          }
        }
        .frame(height: min(480, max(80, session.height)))
      } else if let message = session.message {
        HStack {
          Text(message).foregroundStyle(.secondary)
          if loader != nil && !session.empty {
            Button("Retry") { retry += 1 }
          }
        }
        .font(.subheadline)
      }
    }
    .task(id: LoadID(source: loader?.id, path: reference.path, retry: retry, wide: reference.mode == "wide")) {
      await session.load(path: reference.path, wide: reference.mode == "wide", loader: loader)
    }
    .sheet(isPresented: $expanded) {
      NavigationStack {
        VisualizationWebView(session: session)
          .navigationTitle(title)
          .navigationBarTitleDisplayMode(.inline)
          .toolbar {
            if let scope {
              ToolbarItem(placement: .principal) {
                VStack(spacing: 2) {
                  scope
                  Text(title).font(.caption).foregroundStyle(.secondary)
                }
              }
            }
            ToolbarItem(placement: .confirmationAction) {
              Button("Done") { expanded = false }
            }
          }
      }
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
      ready = true
      loading = false
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
    let url = navigationAction.request.url
    let allowed = navigationAction.navigationType == .other
      && url?.scheme == "about" && (url?.path == "blank" || url?.path == "srcdoc")
    decisionHandler(allowed ? .allow : .cancel)
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

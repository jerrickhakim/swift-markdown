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

private struct VisualizationExpansionAnimationKey: EnvironmentKey {
  static let defaultValue: Animation? = nil
}

extension View {
  public func markdownVisualizationExpansionAnimation(_ animation: Animation?) -> some View {
    environment(\.visualizationExpansionAnimation, animation)
  }

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
  var visualizationExpansionAnimation: Animation? {
    get { self[VisualizationExpansionAnimationKey.self] }
    set { self[VisualizationExpansionAnimationKey.self] = newValue }
  }

  var visualizationCardFill: Color {
    get { self[VisualizationCardFillKey.self] }
    set { self[VisualizationCardFillKey.self] = newValue }
  }

  var visualizationLoader: VisualizationLoader? {
    get { self[VisualizationLoaderKey.self] }
    set { self[VisualizationLoaderKey.self] = newValue }
  }
}

private struct VisualizationLoadID: Hashable {
  let source: AnyHashable?
  let path: String
  let retry: Int
  let wide: Bool
}

struct MarkdownVisualizationView: View {
  let reference: MarkdownVisualizationReference
  @Environment(\.visualizationLoader) private var loader
  @Environment(\.visualizationCardFill) private var cardFill
  @Environment(\.visualizationExpansionAnimation) private var expansionAnimation
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @StateObject private var session = VisualizationSession()
  @State private var expanded = false
  @State private var inlineExpanded = false
  @State private var retry = 0
  @State private var requested = false

  private var request: VisualizationLoadID? {
    guard requested else { return nil }
    return VisualizationLoadID(source: loader?.id, path: reference.path,
                               retry: retry, wide: reference.mode == "wide")
  }

  private var title: String {
    let title = reference.title?.trimmingCharacters(in: .whitespacesAndNewlines)
    return title.flatMap { $0.isEmpty ? nil : $0 } ?? "Preview"
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 0) {
        Button(action: openSheet) {
          Text(title)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.primary)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
            .padding(.leading, 16)
            .padding(.vertical, 16)
            .frame(minHeight: 64)
            .contentShape(Rectangle())
        }
        .layoutPriority(1)
        .accessibilityHint("Opens preview sheet")

        Button {
          UIImpactFeedbackGenerator(style: .light).impactOccurred()
          requested = true
          withAnimation(reduceMotion ? nil : expansionAnimation) {
            inlineExpanded.toggle()
          }
        } label: {
          Image(systemName: inlineExpanded
            ? "arrow.down.right.and.arrow.up.left"
            : "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 44, height: 64)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(inlineExpanded ? "Collapse preview" : "Expand preview inline")

        Button(action: openSheet) {
          HStack {
            Spacer(minLength: 12)
            Image(systemName: "globe")
              .font(.system(size: 32, weight: .light))
              .rotationEffect(.degrees(15))
              .offset(x: 3, y: 3)
              .accessibilityHidden(true)
          }
          .foregroundStyle(.primary)
          .padding(.trailing, 16)
          .frame(maxWidth: .infinity, minHeight: 64)
          .contentShape(Rectangle())
        }
        .accessibilityLabel("Open preview sheet")
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
    .task(id: request) {
      guard let request else { return }
      await session.load(request, loader: loader)
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
      .presentationDetents([.medium, .large])
      .presentationDragIndicator(.visible)
    }
  }

  private func openSheet() {
    requested = true
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    expanded = true
  }

  @ViewBuilder
  private var previewContent: some View {
    switch session.state {
    case .ready:
      VisualizationWebView(session: session)
    case .idle, .loading:
      ProgressView("Loading preview…")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .empty, .unavailable:
      VStack(spacing: 12) {
        Text(session.state == .empty ? "Preview is empty" : "Preview unavailable")
          .foregroundStyle(.secondary)
        if loader != nil && session.state == .unavailable {
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
  enum State { case idle, loading, ready, empty, unavailable }

  @Published private(set) var height: CGFloat = 240
  @Published private(set) var state: State = .idle
  private(set) var webView: WKWebView?
  private var loadedID: VisualizationLoadID?
  private var loadGeneration: UInt64 = 0

  func load(_ request: VisualizationLoadID, loader: VisualizationLoader?) async {
    guard loadedID != request || state == .loading else { return }
    reset()
    loadedID = request
    let generation = loadGeneration
    guard let loader else {
      state = .unavailable
      return
    }
    state = .loading
    do {
      let html = try await loader.load(request.path)
      try Task.checkCancellation()
      guard generation == loadGeneration else { return }
      guard html.utf8.count <= 1_048_576 else {
        state = .unavailable
        return
      }
      guard !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        state = .empty
        return
      }
      let document = try VisualizationDocument.wrap(html, wide: request.wide)
      let configuration = WKWebViewConfiguration()
      configuration.websiteDataStore = .nonPersistent()
      configuration.userContentController.add(VisualizationMessageRelay(self), name: "previewHeight")
      let view = WKWebView(frame: .zero, configuration: configuration)
      view.navigationDelegate = self
      view.isOpaque = false
      view.backgroundColor = .clear
      view.scrollView.backgroundColor = .clear
      webView = view
      view.loadHTMLString(document, baseURL: nil)
    } catch {
      guard generation == loadGeneration else { return }
      if Task.isCancelled || error is CancellationError {
        reset()
      } else {
        state = .unavailable
      }
    }
  }

  private func reset() {
    loadGeneration &+= 1
    webView?.navigationDelegate = nil
    webView?.stopLoading()
    webView?.configuration.userContentController.removeScriptMessageHandler(forName: "previewHeight")
    webView = nil
    loadedID = nil
    state = .idle
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
    state = .ready
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
    state = .unavailable
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

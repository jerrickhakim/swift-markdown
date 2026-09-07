import Foundation
import SwiftUI
import UIKit

// MARK: - Foreground repaint

/// Bumped every time the app returns to the foreground.
///
/// `CodeBlock` reads this in `body`, so the read registers an observation
/// dependency and every code block re-evaluates on foreground; the value also
/// rides in `CodeStreamingText.RenderInputs`, so the text view cannot
/// short-circuit the rebuild on unchanged inputs. Without it a block that came
/// back on screen kept whatever pixels the backgrounding left behind.
@MainActor
@Observable
final class CodeBlockRenderGeneration {
  static let shared = CodeBlockRenderGeneration()

  private(set) var value = 0

  @ObservationIgnored private var observer: NSObjectProtocol?

  private init() {
    observer = NotificationCenter.default.addObserver(
      forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.value &+= 1 }
    }
  }
}

// MARK: - Result cache

/// Highlighted lines, keyed by content + language, living above any view.
///
/// `CodeBlock` is `@State`-backed and SwiftUI destroys and recreates those
/// blocks freely — on foregrounding, the whole message list comes back as new
/// views. Highlighting is cheap, but re-running it for every block on every
/// rebuild is not free, and the cache also keeps a block's colors stable across
/// its own recreation.
///
/// Not keyed by appearance: the colors are dynamic `UIColor`s that resolve
/// light/dark at draw time (`SyntaxTheme.uiColor`).
@MainActor
final class CodeBlockHighlightCache {
  static let shared = CodeBlockHighlightCache()

  /// Bounded because entries hold a full attributed copy of the code. Chats
  /// run long; this keeps the on-screen working set without growing forever.
  private static let capacity = 240

  private var entries: [String: [AttributedString]] = [:]
  /// Insertion order for the eviction sweep — oldest key first.
  private var order: [String] = []

  func lines(for key: String) -> [AttributedString]? { entries[key] }

  func store(_ lines: [AttributedString], for key: String) {
    if entries[key] == nil { order.append(key) }
    entries[key] = lines
    while order.count > Self.capacity {
      entries.removeValue(forKey: order.removeFirst())
    }
  }

  static func key(code: String, language: String) -> String {
    "\(language)|\(code.count)|\(code.hashValue)"
  }
}

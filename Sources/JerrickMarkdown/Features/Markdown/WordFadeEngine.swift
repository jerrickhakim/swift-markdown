import UIKit

// MARK: - Word fade engine

/// One word reveal: a UTF-16 range in the current text, fading in on its own
/// schedule.
private struct FadingWord {
  let range: NSRange
  var start: TimeInterval
  var duration: TimeInterval
  var lastAlphaBucket = -1
  var end: TimeInterval { start + duration }
}

/// CADisplayLink retains its target; this proxy breaks the cycle so the
/// engine (and its text view) can deinit normally.
private final class DisplayLinkProxy {
  weak var target: WordFadeEngine?
  @objc func tick(_ link: CADisplayLink) {
    guard let target else {
      link.invalidate()
      return
    }
    target.fadeTick()
  }
}

/// The streaming word reveal, shared by prose (`SelectableTextView`) and code
/// (`CodeStreamingTextView`). Drives a UITextView's text storage directly:
/// new text appends with its words' colors at alpha 0, and a CADisplayLink
/// steps each word's alpha along an ease-out curve.
/// `foregroundColor`/`backgroundColor` are display-only attributes in TextKit
/// — per-frame writes redraw only the affected line fragments at the tail, no
/// re-layout. Words reveal one at a time regardless of how the stream chunks
/// them: each starts one `wordStep` after the previous. The wave-front's
/// CADENCE is dynamic — the further behind it falls, the faster it sweeps
/// (up to `maxSpeedup`) — but every word's fade lasts the full
/// `fadeDuration`, so the effect stays visible at any stream speed and
/// catch-up reads as a faster cascade, never a dump.
///
/// Attribute-only updates (same text, new colors — a late syntax highlight,
/// a link completing) keep the fade mid-flight: the per-frame pass re-reads
/// base colors from the latest `pristine`, so fading words seamlessly
/// continue fading into their new colors.
final class WordFadeEngine {
  weak var textView: UITextView?

  private let epoch = CACurrentMediaTime()
  /// The latest fully-styled content; fading restores attribute slices from
  /// here so links/code keep their exact colors.
  private var pristine = NSAttributedString()
  /// Queued + in-flight word reveals, in sequential start order.
  private var words: [FadingWord] = []
  /// Index of the first active word in `words`. Finished words advance this
  /// cursor instead of using `removeFirst()`, which shifts the whole array.
  private var firstActiveWord = 0
  /// True once any content has been set with `animated: true`; lets the
  /// final growth (the released held-back word, arriving with
  /// `animated: false`) still fade instead of popping.
  private var hasStreamed = false
  private var displayLink: CADisplayLink?
  private lazy var displayLinkProxy: DisplayLinkProxy = {
    let proxy = DisplayLinkProxy()
    proxy.target = self
    return proxy
  }()
  /// Settles any in-flight reveal when the app backgrounds (see `init`).
  private var backgroundObserver: NSObjectProtocol?

  // Pacing knobs — tune the reveal feel here. The two speeds are DECOUPLED:
  // every word fades over the same fixed `fadeDuration` (the effect is always
  // visible), and only the CADENCE — how fast the wave-front sweeps — scales
  // with backlog. Overlapping long fades read as a soft cascade no matter how
  // hard the cadence accelerates; scaling the fade itself is what turned
  // catch-up into an invisible blink.
  /// Time each word takes to fade in. Never scaled.
  private static let fadeDuration: TimeInterval = 0.45
  /// Nominal gap between consecutive word STARTS when the reveal is keeping
  /// up with the stream. Well under `fadeDuration` so several words are
  /// always mid-fade at once — one continuous wave.
  private static let wordStep: TimeInterval = 0.12
  /// Backlog (seconds of queued-but-unrevealed text) at which the cadence
  /// runs at full `maxSpeedup`; below it, speed ramps smoothly from 1x so
  /// there's no gear-shift between "keeping up" and "catching up".
  private static let maxLag: TimeInterval = 1.0
  /// Cap on how much the cadence accelerates under backlog. High on purpose:
  /// it only tightens word-start spacing (down to `wordStep / maxSpeedup` =
  /// 15ms), never the fades themselves.
  private static let maxSpeedup: Double = 8
  /// Alpha quantization for TextKit writes. The ease curve is unchanged, but
  /// attributes are rewritten only when a word crosses a visible alpha step.
  private static let alphaBuckets = 48
  /// Max reveal tiles per growth step. A bigger growth (multiple settled
  /// parts landing at once, reconnect catch-up) is grouped into at most this
  /// many word-batches that cascade at the accelerated cadence — a fast,
  /// visible sweep instead of an instant pop. Worst case is bounded:
  /// 40 tiles × 15ms + one 0.45s fade ≈ 1s to fully reveal any dump.
  private static let maxTilesPerGrowth = 40

  init() {
    // The reveal is driven by a CADisplayLink, which the system PAUSES the
    // moment the app leaves the foreground. A word caught mid-fade then holds
    // its partial alpha indefinitely — on return the whole block reads as a
    // dimmed, half-revealed wall because the fade never resumed to completion.
    // Snap every in-flight reveal to its final colors on backgrounding so
    // there's no frozen partial-alpha state to come back to. Mirrors the
    // off-screen reclaim path (`willMove(toWindow: nil)` → `settleInstantly()`).
    backgroundObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.didEnterBackgroundNotification,
      object: nil, queue: .main
    ) { [weak self] _ in
      self?.settleInstantly()
    }
  }

  deinit {
    displayLink?.invalidate()
    if let backgroundObserver {
      NotificationCenter.default.removeObserver(backgroundObserver)
    }
  }

  // MARK: Content

  /// Replaces the view's content, queueing fades for appended words.
  /// Returns true when the content actually changed (the caller should
  /// invalidate its measurement cache).
  @discardableResult
  func setContents(_ attributed: NSAttributedString, animated: Bool) -> Bool {
    guard let view = textView else { return false }
    // Register streaming intent BEFORE the equality guard. A single-word block
    // (a one-word heading, a lone-word paragraph) holds its only word back the
    // whole time it streams, so every animated update here carries empty
    // committed text and would early-return — leaving `hasStreamed` false and
    // making the final release at settle look like a fresh history load that
    // pops. Marking it on any animated call keeps the released word fading.
    if animated { hasStreamed = true }
    guard !pristine.isEqual(to: attributed) else { return false }
    let oldPlain = pristine.string
    let newPlain = attributed.string

    let wantsFade = animated || hasStreamed
    pristine = attributed

    if newPlain != oldPlain {
      let isGrowth =
        newPlain.utf16.count > oldPlain.utf16.count && newPlain.hasPrefix(oldPlain)
      // `hasStreamed` lets a block that streamed entirely held-back (empty →
      // full word at settle, animated:false) still fade; genuine history loads
      // never set it, so they stay pop-free.
      if wantsFade, isGrowth, !oldPlain.isEmpty || animated || hasStreamed {
        let growth = NSRange(
          location: oldPlain.utf16.count, length: newPlain.utf16.count - oldPlain.utf16.count)
        let tiles = Self.wordTiles(in: newPlain, utf16Range: growth)
        queueWords(Self.grouped(tiles, maxCount: Self.maxTilesPerGrowth))
      } else {
        // Initial set (history load), shrink, or mid-text change from a
        // re-parse: render settled. In-flight words whose ranges may no
        // longer be valid are dropped.
        clearWords()
      }
    }
    // else: attribute-only update — keep the queue, fades continue into the
    // new colors.

    view.attributedText = attributed
    // Hide queued/in-flight words again in the same transaction — the
    // attributedText assignment above made them fully visible, so every pending
    // word (including the not-yet-started ones) must be re-hidden here.
    applyFadeFrame(at: now(), afterContentReset: true)
    syncDisplayLink()
    return true
  }

  /// Finishes all pending reveals immediately (row reclaimed off-screen).
  func settleInstantly() {
    guard hasActiveWords, let storage = textView?.textStorage else { return }
    let limit = (pristine.string as NSString).length
    storage.beginEditing()
    for word in words[firstActiveWord...] { restore(word.range, in: storage, limit: limit) }
    storage.endEditing()
    clearWords()
    syncDisplayLink()
  }

  // MARK: Clock

  private func now() -> TimeInterval { CACurrentMediaTime() - epoch }

  /// Appends one growth's tiles to the reveal queue. Chunk boundaries don't
  /// matter — every tile starts one (backlog-scaled) `wordStep` after the
  /// previous one. The backlog is recomputed per tile, so a big growth
  /// naturally accelerates toward its tail and the queue self-bounds. Only
  /// the cadence scales; every tile fades over the full `fadeDuration`.
  private func queueWords(_ tiles: [NSRange]) {
    let now = now()
    for tile in tiles {
      let lastStart = activeLastStart
      let lag = max(0, (lastStart ?? now) - now)
      let speed = 1 + (Self.maxSpeedup - 1) * min(1, lag / Self.maxLag)
      let start = lastStart.map { max(now, $0 + Self.wordStep / speed) } ?? now
      words.append(
        FadingWord(range: tile, start: start, duration: Self.fadeDuration))
    }
  }

  fileprivate func fadeTick() {
    let tickNow = now()
    applyFadeFrame(at: tickNow, afterContentReset: false)
    syncDisplayLink()
  }

  /// Writes this frame's alphas: finished words restore their pristine
  /// attribute slice (and are pruned), in-flight words get their colors
  /// alpha-scaled, unstarted words stay invisible. Display-only writes —
  /// TextKit redraws just the affected fragments.
  ///
  /// PERF: per-frame cost is bounded to the words actually in flight. Words are
  /// queued in `start` order, so once we reach one that hasn't started it and
  /// every word after it are still at alpha 0 from the frame that queued them —
  /// re-writing 0 each frame is wasted TextKit churn (worst during a catch-up
  /// burst, where dozens of tiles can be queued ahead of the wave front). We
  /// stop at the wave front instead. The exception is `afterContentReset`: the
  /// `view.attributedText` reassignment just made everything fully visible, so
  /// there every pending word must be walked and re-hidden.
  private func applyFadeFrame(at time: TimeInterval, afterContentReset: Bool) {
    guard hasActiveWords, let storage = textView?.textStorage else { return }
    let limit = (pristine.string as NSString).length
    storage.beginEditing()

    // Fold finished reveals from the front (starts are sequential).
    while firstActiveWord < words.count, time >= words[firstActiveWord].end {
      let first = words[firstActiveWord]
      restore(first.range, in: storage, limit: limit)
      firstActiveWord += 1
    }
    var index = firstActiveWord
    while index < words.count {
      let word = words[index]
      let progress = (time - word.start) / word.duration
      if progress <= 0 {
        // Unstarted: already hidden, and so is every later word. Only re-hide
        // when a content reset made them visible; otherwise stop here.
        if afterContentReset {
          setAlpha(0, in: word.range, storage: storage, limit: limit)
          words[index].lastAlphaBucket = 0
          index += 1
          continue
        }
        break
      }
      let alpha = easeOut(min(1, progress))
      let bucket = Int((alpha * Double(Self.alphaBuckets)).rounded())
      if afterContentReset || words[index].lastAlphaBucket != bucket {
        words[index].lastAlphaBucket = bucket
        setAlpha(Double(bucket) / Double(Self.alphaBuckets), in: word.range, storage: storage, limit: limit)
      }
      index += 1
    }

    storage.endEditing()
    compactFinishedWordsIfNeeded()
  }

  private func restore(_ range: NSRange, in storage: NSTextStorage, limit: Int) {
    guard let clamped = clamp(range, to: limit) else { return }
    pristine.enumerateAttributes(in: clamped) { attrs, sub, _ in
      var slice: [NSAttributedString.Key: Any] = [:]
      slice[.foregroundColor] = attrs[.foregroundColor]
      if let bg = attrs[.backgroundColor] { slice[.backgroundColor] = bg }
      storage.addAttributes(slice.compactMapValues { $0 }, range: sub)
    }
  }

  private func setAlpha(
    _ alpha: Double, in range: NSRange, storage: NSTextStorage, limit: Int
  ) {
    guard let clamped = clamp(range, to: limit) else { return }
    pristine.enumerateAttributes(in: clamped) { attrs, sub, _ in
      let base = (attrs[.foregroundColor] as? UIColor) ?? .label
      storage.addAttribute(
        .foregroundColor, value: base.scaledAlpha(alpha), range: sub)
      // Inline-code chips fade with their text instead of popping at full
      // strength under invisible glyphs.
      if let bg = attrs[.backgroundColor] as? UIColor {
        storage.addAttribute(.backgroundColor, value: bg.scaledAlpha(alpha), range: sub)
      }
    }
  }

  private func clamp(_ range: NSRange, to limit: Int) -> NSRange? {
    let location = min(range.location, limit)
    let length = min(range.length, limit - location)
    guard length > 0 else { return nil }
    return NSRange(location: location, length: length)
  }

  /// Runs the display link only while words are in flight.
  private func syncDisplayLink() {
    if !hasActiveWords {
      displayLink?.invalidate()
      displayLink = nil
    } else if displayLink == nil {
      let link = CADisplayLink(
        target: displayLinkProxy, selector: #selector(DisplayLinkProxy.tick(_:)))
      link.add(to: .main, forMode: .common)
      displayLink = link
    }
  }

  private func easeOut(_ t: Double) -> Double {
    1 - (1 - t) * (1 - t)
  }

  private var hasActiveWords: Bool { firstActiveWord < words.count }
  private var activeLastStart: TimeInterval? {
    hasActiveWords ? words[words.count - 1].start : nil
  }

  private func clearWords() {
    words.removeAll(keepingCapacity: true)
    firstActiveWord = 0
  }

  private func compactFinishedWordsIfNeeded() {
    guard firstActiveWord > 0 else { return }
    if firstActiveWord == words.count {
      clearWords()
    } else if firstActiveWord >= 16 {
      words.removeFirst(firstActiveWord)
      firstActiveWord = 0
    }
  }

  // MARK: Word tiling

  /// Merges consecutive word tiles into at most `maxCount` contiguous
  /// batches, evenly sized. Small growths pass through one-tile-per-word;
  /// a dump cascades in word-groups instead of popping in whole.
  private static func grouped(_ tiles: [NSRange], maxCount: Int) -> [NSRange] {
    guard tiles.count > maxCount, maxCount > 0 else { return tiles }
    var result: [NSRange] = []
    result.reserveCapacity(maxCount)
    let stride = Double(tiles.count) / Double(maxCount)
    var start = 0
    for batch in 1...maxCount {
      let end = batch == maxCount ? tiles.count : Int((Double(batch) * stride).rounded())
      guard end > start else { continue }
      let first = tiles[start]
      let last = tiles[end - 1]
      result.append(
        NSRange(location: first.location, length: last.upperBound - first.location))
      start = end
    }
    return result
  }

  /// Splits a growth region into contiguous tiles, one per word, each tile
  /// carrying the whitespace/punctuation gap that precedes its word — the
  /// tiles exactly cover the region. Locale-aware (`.byWords`) so CJK
  /// reveals word-by-word too. Ranges are UTF-16 (NSAttributedString space).
  private static func wordTiles(in plain: String, utf16Range: NSRange) -> [NSRange] {
    guard let swiftRange = Range(utf16Range, in: plain) else { return [] }

    var tiles: [NSRange] = []
    var tileStart = utf16Range.location
    plain.enumerateSubstrings(
      in: swiftRange, options: [.byWords, .localized, .substringNotRequired]
    ) { _, wordRange, _, _ in
      let end = NSRange(wordRange, in: plain).upperBound
      if end > tileStart {
        tiles.append(NSRange(location: tileStart, length: end - tileStart))
        tileStart = end
      }
    }
    // Trailing gap (or no words at all): extend/emit a final tile.
    let upper = utf16Range.upperBound
    if tileStart < upper {
      if tiles.isEmpty {
        tiles.append(NSRange(location: tileStart, length: upper - tileStart))
      } else {
        let last = tiles[tiles.count - 1]
        tiles[tiles.count - 1] = NSRange(
          location: last.location, length: upper - last.location)
      }
    }
    return tiles
  }
}

extension UIColor {
  /// Multiplies the color's existing alpha (link/code colors may already be
  /// translucent) instead of overwriting it.
  fileprivate func scaledAlpha(_ alpha: Double) -> UIColor {
    withAlphaComponent(cgColor.alpha * alpha)
  }
}

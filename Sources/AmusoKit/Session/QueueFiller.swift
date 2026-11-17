import Foundation
import OSLog

/// What filling the queue came to.
nonisolated public struct QueueFillOutcome: Sendable, Hashable {
  /// Items the player took.
  public var added = 0
  /// Items whose batch failed once failures no longer ended the fill: after playback started, or
  /// after the first batch of a Play Next or Play Last.
  public var leftOut = 0
  /// What the last failed batch met, when some were left out.
  public var error: SonosError?
  /// Items the player refused on their own (UPnP error 800): an id it cannot find, such as a
  /// catalog id Apple has since replaced. The rest of their batch went in without them.
  public var refused: [EnqueueItem] = []
  /// Whether the fill stopped because the player refused the first songs one after another with
  /// none taken: what it does when the Apple Music account the household plays with cannot see
  /// any of them (another account, another country). The rest was not tried.
  public var stoppedOnRefusals = false
  /// Whether another fill replaced the queue, or the task was cancelled, before this one was done.
  public var wasSuperseded = false

  public init(
    added: Int = 0,
    leftOut: Int = 0,
    error: SonosError? = nil,
    refused: [EnqueueItem] = [],
    stoppedOnRefusals: Bool = false,
    wasSuperseded: Bool = false
  ) {
    self.added = added
    self.leftOut = leftOut
    self.error = error
    self.refused = refused
    self.stoppedOnRefusals = stoppedOnRefusals
    self.wasSuperseded = wasSuperseded
  }
}

/// How far a queue fill has got, for the app to show while it runs: a five-hundred-song Shuffle is
/// minutes on a slow system.
nonisolated public struct QueueFillProgress: Sendable, Hashable {
  /// Items dealt with so far: taken, refused or left out.
  public var processed: Int
  /// Items the fill was given.
  public var total: Int

  public init(processed: Int = 0, total: Int) {
    self.processed = processed
    self.total = total
  }

  /// From 0 to 1.
  public var fraction: Double {
    total > 0 ? min(1, Double(processed) / Double(total)) : 0
  }
}

/// Adds items to a queue sixteen at a time, the most `AddMultipleURIsToQueue` takes, and copes
/// with a player slow to answer or refusing an item:
///
/// - a batch that met no answer (`SonosError.unreachable`) is tried once more, unless the queue's
///   length shows the player took it and only answered late;
/// - a batch the player refused (UPnP error 800, which it answers for the whole batch when it
///   cannot find one item) is split in halves, down to the items it refuses on their own, which
///   are left out and named in the outcome; when the first `refusalsBeforeGivingUp` are refused
///   with none taken, the fill stops there, the account rather than the songs being at fault;
/// - until the item at `required` is in (or, when it was refused, the next one), a failed batch
///   ends the fill with its error; after, the fill goes on with the next batches and counts the
///   failed ones' items as left out, giving up on the rest after `consecutiveFailureLimit` failed
///   batches in a row;
/// - every batch's duration and every failure are logged, to compare one system with another, and
///   handed to `didCall`, for the journal a host app's diagnostics report (`QueueFillJournal`).
///
/// The operations are injected, so that the session drives the players with it and the tests
/// drive it with neither.
nonisolated struct QueueFiller {
  /// Adds one batch at `position` (1-based; 0 appends).
  var add: (_ batch: [EnqueueItem], _ position: Int) async throws -> QueueAddResult
  /// The queue's length, read after a batch met no answer.
  var readQueueLength: () async throws -> Int
  /// Runs after each batch is in: where the session bumps its queue version.
  var didAdd: () -> Void = {}
  /// Runs once, as soon as the item at `required` is in, with its position in the queue (1-based,
  /// counted from the first item added): where `replaceQueue` starts playback. The position is
  /// lower than `required` when items before it were refused, and is the next item's when it was
  /// refused itself. A throw ends the fill with that error.
  var requiredAreIn: (_ startPosition: Int) async throws -> Void = { _ in }
  /// Whether the fill is still wanted: no longer once another replaced the queue.
  var isCurrent: () -> Bool = { true }
  /// Runs after each call to the player, taken or not: where the session keeps its journal.
  var didCall: (QueueFillRecord.Call) -> Void = { _ in }
  /// Runs whenever more items have been dealt with (taken, refused or left out), with how many
  /// so far: where the session says how far the fill has got.
  var didProgress: (_ processed: Int) -> Void = { _ in }
  var batchSize = 16
  /// Tries per batch, the first included.
  var attempts = 2
  var consecutiveFailureLimit = 3
  /// Songs refused with none taken before the fill stops. A refusal takes about 0.35 s on an
  /// Era 300 pair, so four (nine calls) is about three seconds, where a whole batch
  /// would be thirty-one calls.
  var refusalsBeforeGivingUp = 4
  var log = Logger(subsystem: Diagnostics.subsystem, category: "Queue")

  /// Adds `items` at `position` (1-based; 0 appends), after the current track when `asNext`.
  /// `knownLength` is the queue's length before, when known (0 after clearing it); `required` the
  /// item (1-based) that must be in before a failed batch stops ending the fill.
  func fill(
    _ items: [EnqueueItem],
    position: Int = 0,
    asNext: Bool = false,
    knownLength: Int? = nil,
    required: Int
  ) async throws -> QueueFillOutcome {
    // Ranges of `items`, in order: the batches, and the halves of those the player refused.
    var pending = Self.batchRanges(count: items.count, size: batchSize)
    let batchCount = pending.count
    var progress = Progress(offset: position, length: knownLength, required: required)
    while !pending.isEmpty {
      let range = pending.removeFirst()
      let batch = Array(items[range])
      guard isCurrent(), !Task.isCancelled else {
        log.notice("Queue fill superseded after \(progress.outcome.added) of \(items.count) items")
        progress.outcome.wasSuperseded = true
        return progress.outcome
      }
      let label = label(for: range, of: items.count, batchCount: batchCount)
      switch await send(batch, label: label, asNext: asNext, progress: progress) {
      case .added(let result):
        progress.took(batch.count, result: result, asNext: asNext)
        didAdd()
        didProgress(progress.processed)
      case .failed(let error, _) where Self.isRefusal(error):
        // A refusal never lets playback start: the item at `required`, or the next one in, is
        // still to come.
        if refuse(range, of: items, label: label, pending: &pending, progress: &progress) {
          return progress.outcome
        }
        continue
      case .failed(let error, let lengthAfter):
        guard progress.started else {
          log.error("\(label, privacy: .public) ended the queue fill: \(error.description, privacy: .public)")
          throw error
        }
        if fail(batch.count, error: error, lengthAfter: lengthAfter, of: items.count, progress: &progress) {
          return progress.outcome
        }
        continue
      }
      if progress.start() {
        try await requiredAreIn(progress.startPosition)
      }
    }
    // The item at `required` and every one after it were refused: start at the last one in.
    if !progress.started, progress.outcome.added > 0 {
      try await requiredAreIn(min(progress.startPosition, progress.outcome.added))
    }
    logDone(progress.outcome, of: items.count, batchCount: batchCount)
    return progress.outcome
  }

  /// Where a fill stands.
  private struct Progress {
    var outcome = QueueFillOutcome()
    /// Where the next batch goes (1-based; 0 appends).
    var offset: Int
    var length: Int?
    let required: Int
    var failuresInARow = 0
    /// Items taken, refused or left out, from the first.
    var processed = 0
    var refusedBeforeStart = 0
    var started: Bool
    /// When the fill began, to time each call from.
    let began = ContinuousClock.now

    init(offset: Int, length: Int?, required: Int) {
      self.offset = offset
      self.length = length
      self.required = required
      started = required <= 0
    }

    /// Where the item at `required` is in the queue, counted from the first added.
    var startPosition: Int { max(1, required - refusedBeforeStart) }

    /// Whether playback starts now: the item at `required`, or the next one in when it was
    /// refused, has just gone in.
    mutating func start() -> Bool {
      guard !started, processed >= required, outcome.added >= startPosition else { return false }
      started = true
      return true
    }

    mutating func took(_ count: Int, result: QueueAddResult, asNext: Bool) {
      failuresInARow = 0
      processed += count
      outcome.added += count
      length = result.newQueueLength > 0 ? result.newQueueLength : length.map { $0 + count }
      if offset > 0 || asNext, result.firstTrackNumberEnqueued > 0 {
        offset = result.firstTrackNumberEnqueued + result.numberOfTracksAdded
      }
    }

    /// `item`, at `index` (0-based) of the items, refused on its own.
    mutating func refused(_ item: EnqueueItem, at index: Int) {
      processed += 1
      outcome.refused.append(item)
      if index < required - 1 {
        refusedBeforeStart += 1
      }
    }

    mutating func failed(_ count: Int, error: SonosError, lengthAfter: Int?) {
      processed += count
      failuresInARow += 1
      outcome.leftOut += count
      outcome.error = error
      length = lengthAfter
    }
  }

  /// Splits a refused batch in halves, to be tried first, or leaves out the item refused on its
  /// own; whether the fill stops, the first songs all refused.
  private func refuse(
    _ range: Range<Int>, of items: [EnqueueItem], label: String, pending: inout [Range<Int>], progress: inout Progress
  ) -> Bool {
    guard range.count == 1 else {
      let middle = range.lowerBound + range.count / 2
      pending.insert(contentsOf: [range.lowerBound..<middle, middle..<range.upperBound], at: 0)
      log.notice("\(label, privacy: .public): refused, tried again in halves")
      return false
    }
    let item = items[range.lowerBound]
    progress.refused(item, at: range.lowerBound)
    didProgress(progress.processed)
    log.error("\(label, privacy: .public): the player refused \(item.uri, privacy: .public), left out")
    guard progress.outcome.added == 0, progress.outcome.refused.count >= refusalsBeforeGivingUp else { return false }
    log.error("Gave up on the queue: the player refused the first \(refusalsBeforeGivingUp) songs")
    progress.outcome.stoppedOnRefusals = true
    return true
  }

  /// Counts a failed batch as left out; whether the fill gives up on the rest, too many failed in
  /// a row.
  private func fail(
    _ count: Int, error: SonosError, lengthAfter: Int?, of total: Int, progress: inout Progress
  ) -> Bool {
    progress.failed(count, error: error, lengthAfter: lengthAfter)
    didProgress(progress.processed)
    guard progress.failuresInARow >= consecutiveFailureLimit else { return false }
    let rest = total - progress.processed
    let failures = progress.failuresInARow
    progress.outcome.leftOut += rest
    log.error("""
      Gave up on the queue after \(failures) failed batches in a row: \
      \(rest) more items left out
      """)
    return true
  }

  private func label(for range: Range<Int>, of count: Int, batchCount: Int) -> String {
    let batch = "Batch \(range.lowerBound / batchSize + 1)/\(batchCount)"
    if range.lowerBound % batchSize == 0, range.count == min(batchSize, count - range.lowerBound) {
      return batch
    }
    return range.count == 1
      ? "\(batch), item \(range.upperBound)"
      : "\(batch), items \(range.lowerBound + 1)–\(range.upperBound)"
  }

  private func logDone(_ outcome: QueueFillOutcome, of count: Int, batchCount: Int) {
    if outcome.leftOut > 0 || !outcome.refused.isEmpty {
      log.error("""
        Queue filled with \(outcome.added) of \(count) items, \(outcome.leftOut) left out, \
        \(outcome.refused.count) refused
        """)
    } else {
      log.info("Queue filled with \(outcome.added) items in \(batchCount) batches")
    }
  }

  /// UPnP error 800: what a player answers, for the whole call, when it cannot find or reconcile
  /// one of the items (README, _Apple Music_).
  static func isRefusal(_ error: SonosError) -> Bool {
    guard case .fault(let fault, _) = error else { return false }
    return fault.upnpErrorCode == 800
  }

  private enum BatchResult {
    case added(QueueAddResult)
    /// With the queue's length after, when it was read.
    case failed(SonosError, lengthAfter: Int?)
  }

  /// One batch, tried again after no answer unless the player turns out to have taken it, sent
  /// where `progress` is.
  private func send(_ batch: [EnqueueItem], label: String, asNext: Bool, progress: Progress) async -> BatchResult {
    let position = progress.offset
    let knownLength = progress.length
    let clock = ContinuousClock()
    var attempt = 1
    while true {
      let start = clock.now
      var call = QueueFillRecord.Call(
        label: label, count: batch.count, attempt: attempt, sentAfter: start - progress.began, duration: .zero)
      do {
        let result = try await add(batch, position)
        call.duration = clock.now - start
        let elapsed = Self.milliseconds(call.duration)
        log.info("\(label, privacy: .public): \(batch.count) items in \(elapsed) ms, try \(attempt)")
        didCall(call)
        return .added(result)
      } catch {
        call.duration = clock.now - start
        let elapsed = Self.milliseconds(call.duration)
        let error = (error as? SonosError) ?? .invalidResponse(error.localizedDescription)
        call.error = error
        log.error("""
          \(label, privacy: .public): \(batch.count) items failed after \(elapsed) ms, try \(attempt): \
          \(error.description, privacy: .public)
          """)
        guard case .unreachable = error else {
          didCall(call)
          return .failed(error, lengthAfter: knownLength)
        }
        let lengthAfter = try? await readQueueLength()
        if let late = Self.lateAnswer(
          batch: batch.count, position: position, asNext: asNext, before: knownLength, after: lengthAfter) {
          log.notice("\(label, privacy: .public): the player took it but answered late")
          call.answeredLate = true
          didCall(call)
          return .added(late)
        }
        didCall(call)
        guard attempt < attempts, isCurrent(), !Task.isCancelled else {
          return .failed(error, lengthAfter: lengthAfter)
        }
        attempt += 1
      }
    }
  }

  /// What a batch that met no answer came to, when the queue's length shows the player took it:
  /// the length grew by the batch, and where the batch went is known (appended, or at a position;
  /// not after the current track, whose number may have changed).
  static func lateAnswer(batch: Int, position: Int, asNext: Bool, before: Int?, after: Int?) -> QueueAddResult? {
    guard let before, let after, after >= before + batch, position > 0 || !asNext else { return nil }
    return QueueAddResult(
      firstTrackNumberEnqueued: position > 0 ? position : before + 1,
      numberOfTracksAdded: batch,
      newQueueLength: after
    )
  }

  static func batches(of items: [EnqueueItem], size: Int = 16) -> [[EnqueueItem]] {
    batchRanges(count: items.count, size: size).map { Array(items[$0]) }
  }

  static func batchRanges(count: Int, size: Int = 16) -> [Range<Int>] {
    stride(from: 0, to: count, by: size).map { $0..<min($0 + size, count) }
  }

  private static func milliseconds(_ duration: Duration) -> Int {
    Int(duration / .milliseconds(1))
  }
}

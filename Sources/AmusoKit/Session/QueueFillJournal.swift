import Foundation

/// What one queue fill did, call by call, for a host app's diagnostics: counts, timings and errors,
/// no titles.
nonisolated public struct QueueFillRecord: Sendable, Hashable, Identifiable {
  public enum Kind: Sendable, Hashable {
    /// `replaceQueue`, playing from the item at `startIndex` (1-based) in `playMode`.
    case replace(startIndex: Int, playMode: PlayMode)
    /// `enqueue`: after the current track when `asNext` (Play Next), else at the end (Play Last).
    case add(asNext: Bool)
  }

  /// One call to the player: a batch, a half of a refused one, or a single item, at one try.
  public struct Call: Sendable, Hashable {
    /// "Batch 3/32", or "Batch 3/32, items 33–40" for part of one.
    public var label: String
    public var count: Int
    /// The try, from 1.
    public var attempt: Int
    /// When the call was sent, counted from the fill's start.
    public var sentAfter: Duration
    public var duration: Duration
    /// What it met, or `nil` when the player took it.
    public var error: SonosError?
    /// Whether the player took a call that met no answer, as the queue's length then showed.
    public var answeredLate: Bool

    public init(
      label: String,
      count: Int,
      attempt: Int,
      sentAfter: Duration,
      duration: Duration,
      error: SonosError? = nil,
      answeredLate: Bool = false
    ) {
      self.label = label
      self.count = count
      self.attempt = attempt
      self.sentAfter = sentAfter
      self.duration = duration
      self.error = error
      self.answeredLate = answeredLate
    }
  }

  public enum Status: Sendable, Hashable {
    /// Not over yet: still adding, or stopped where the app was suspended.
    case running
    case finished(QueueFillOutcome)
    /// Thrown before the item playback starts at was in, or by a call around the fill.
    case failed(SonosError)
  }

  public let id: Int
  /// When it began, on the wall clock.
  public let start: Date
  /// The room, or group of rooms, it filled.
  public let room: String
  public let kind: Kind
  public let itemCount: Int
  public internal(set) var calls: [Call] = []
  public internal(set) var status: Status = .running
  /// How long it took, once over.
  public internal(set) var duration: Duration?

  public init(
    id: Int,
    start: Date,
    room: String,
    kind: Kind,
    itemCount: Int,
    calls: [Call] = [],
    status: Status = .running,
    duration: Duration? = nil
  ) {
    self.id = id
    self.start = start
    self.room = room
    self.kind = kind
    self.itemCount = itemCount
    self.calls = calls
    self.status = status
    self.duration = duration
  }
}

/// The last few queue fills, in memory only, oldest first: what a host app's diagnostics report, so that
/// a user whose queue stopped short can send what each call to the players did. Shared by
/// the sessions, so that changing rooms keeps them.
public final class QueueFillJournal {
  public private(set) var fills: [QueueFillRecord] = []
  /// How many fills are kept.
  public let limit: Int
  private var nextID = 1

  public init(limit: Int = 5) {
    self.limit = max(1, limit)
  }

  /// Starts a record, dropping the oldest past `limit`; returns its id.
  public func begin(room: String, kind: QueueFillRecord.Kind, itemCount: Int, at start: Date = .now) -> Int {
    let id = nextID
    nextID += 1
    fills.append(QueueFillRecord(id: id, start: start, room: room, kind: kind, itemCount: itemCount))
    if fills.count > limit {
      fills.removeFirst(fills.count - limit)
    }
    return id
  }

  public func record(_ call: QueueFillRecord.Call, in id: Int) {
    guard let index = fills.firstIndex(where: { $0.id == id }) else { return }
    fills[index].calls.append(call)
  }

  public func end(_ id: Int, _ status: QueueFillRecord.Status, after duration: Duration) {
    guard let index = fills.firstIndex(where: { $0.id == id }) else { return }
    fills[index].status = status
    fills[index].duration = duration
  }
}

import Foundation
import Testing
@testable import AmusoKit

/// The queue filled sixteen at a time against a make-believe player: a slow one that answers late
/// or not at all, one that refuses, one replaced mid-fill, one that cannot find some songs.
@MainActor
struct QueueFillerTests {
  private static let office = PlayerEndpoint(host: "192.168.1.10")!
  private static let timedOut = SonosError.unreachable(office, reason: "-1001 The request timed out.")
  private static let refusal = SonosError.fault(
    SoapFault(httpStatus: 500, upnpErrorCode: 800), action: "AddMultipleURIsToQueue")

  /// A queue on a player: what it holds, and the batches it is sent, in order.
  private final class FakeQueue {
    var tracks: [String] = []
    var calls: [(count: Int, position: Int)] = []
    var lengthReads = 0
    /// For each call, by number from 1: what goes wrong, and whether the player still takes it.
    var faults: [Int: (error: SonosError, takesItAnyway: Bool)] = [:]
    /// Items it cannot find: as the Era 300 pair does, it refuses any call holding one with UPnP
    /// error 800, and takes none of the call's items.
    var unknownIDs: Set<String> = []

    func add(_ batch: [EnqueueItem], at position: Int) throws -> QueueAddResult {
      calls.append((batch.count, position))
      let first = position > 0 ? position : tracks.count + 1
      if batch.contains(where: { unknownIDs.contains($0.itemID) }) {
        throw QueueFillerTests.refusal
      }
      guard let fault = faults[calls.count] else {
        tracks.insert(contentsOf: batch.map(\.itemID), at: first - 1)
        return QueueAddResult(
          firstTrackNumberEnqueued: first, numberOfTracksAdded: batch.count, newQueueLength: tracks.count)
      }
      if fault.takesItAnyway {
        tracks.insert(contentsOf: batch.map(\.itemID), at: first - 1)
      }
      throw fault.error
    }
  }

  private static func items(_ count: Int) -> [EnqueueItem] {
    (1...count).map { EnqueueItem(uri: "song%3a\($0)", metadata: "", itemID: "\($0)", title: "Song \($0)") }
  }

  private func filler(_ queue: FakeQueue) -> QueueFiller {
    QueueFiller(
      add: { batch, position in try queue.add(batch, at: position) },
      readQueueLength: {
        queue.lengthReads += 1
        return queue.tracks.count
      }
    )
  }

  @Test func sixteenItemsPerCall() async throws {
    let queue = FakeQueue()
    let outcome = try await filler(queue).fill(Self.items(35), knownLength: 0, required: 1)
    #expect(queue.calls.map(\.count) == [16, 16, 3])
    #expect(queue.tracks == Self.items(35).map(\.itemID))
    #expect(outcome == QueueFillOutcome(added: 35))
  }

  /// What the app shows while the queue fills: every song dealt with, taken, refused or left out.
  @Test func progressCountsEverySongDealtWith() async throws {
    let queue = FakeQueue()
    let items = Self.items(40)
    queue.unknownIDs = ["20"]
    let fault = SonosError.fault(SoapFault(httpStatus: 500, upnpErrorCode: 402), action: "AddMultipleURIsToQueue")
    // The second batch is refused and halved down to song 20 (calls 2 to 10); call 11 is the third.
    queue.faults = [11: (fault, false)]
    var filler = filler(queue)
    var reported: [Int] = []
    filler.didProgress = { reported.append($0) }
    let outcome = try await filler.fill(items, knownLength: 0, required: 1)
    #expect(outcome.added == 31)
    #expect(outcome.leftOut == 8)
    #expect(outcome.refused.map(\.itemID) == ["20"])
    #expect(reported == [16, 18, 19, 20, 24, 32, 40])
  }

  @Test func playbackStartsOnceTheBatchHoldingTheStartIsIn() async throws {
    let queue = FakeQueue()
    var filler = filler(queue)
    var callsWhenStarted: [Int] = []
    filler.requiredAreIn = { _ in callsWhenStarted.append(queue.calls.count) }
    _ = try await filler.fill(Self.items(50), knownLength: 0, required: 20)
    #expect(callsWhenStarted == [2])
  }

  @Test func aBatchThatTimedOutIsTriedOnceMore() async throws {
    let queue = FakeQueue()
    queue.faults = [2: (Self.timedOut, false)]
    let outcome = try await filler(queue).fill(Self.items(40), knownLength: 0, required: 1)
    #expect(queue.calls.map(\.count) == [16, 16, 16, 8])
    #expect(queue.tracks == Self.items(40).map(\.itemID))
    #expect(outcome == QueueFillOutcome(added: 40))
  }

  @Test func aBatchThePlayerTookButAnsweredLateIsNotSentTwice() async throws {
    let queue = FakeQueue()
    queue.faults = [2: (Self.timedOut, true)]
    let outcome = try await filler(queue).fill(Self.items(40), knownLength: 0, required: 1)
    #expect(queue.calls.count == 3)
    #expect(queue.lengthReads == 1)
    #expect(queue.tracks == Self.items(40).map(\.itemID))
    #expect(outcome == QueueFillOutcome(added: 40))
  }

  @Test func aFaultIsNotTriedAgain() async throws {
    let queue = FakeQueue()
    let fault = SonosError.fault(SoapFault(httpStatus: 500, upnpErrorCode: 402), action: "AddMultipleURIsToQueue")
    queue.faults = [2: (fault, false)]
    let outcome = try await filler(queue).fill(Self.items(48), knownLength: 0, required: 1)
    #expect(queue.calls.count == 3)
    #expect(queue.lengthReads == 0)
    #expect(outcome == QueueFillOutcome(added: 32, leftOut: 16, error: fault))
  }

  @Test func beforePlaybackStartsAFailedBatchEndsTheFill() async throws {
    let queue = FakeQueue()
    queue.faults = [2: (Self.timedOut, false), 3: (Self.timedOut, false)]
    var filler = filler(queue)
    var started = false
    filler.requiredAreIn = { _ in started = true }
    await #expect(throws: Self.timedOut) {
      try await filler.fill(Self.items(64), knownLength: 0, required: 40)
    }
    #expect(queue.calls.count == 3)
    #expect(!started)
    #expect(queue.tracks.count == 16)
  }

  @Test func afterPlaybackStartsTheFillGoesOnAndCountsWhatWasLeftOut() async throws {
    let queue = FakeQueue()
    queue.faults = [2: (Self.timedOut, false), 3: (Self.timedOut, false)]
    var filler = filler(queue)
    var started = false
    filler.requiredAreIn = { _ in started = true }
    let outcome = try await filler.fill(Self.items(50), knownLength: 0, required: 1)
    #expect(started)
    #expect(queue.calls.map(\.count) == [16, 16, 16, 16, 2])
    #expect(queue.tracks == Array(Self.items(50).map(\.itemID).prefix(16) + Self.items(50).map(\.itemID).suffix(18)))
    #expect(outcome == QueueFillOutcome(added: 34, leftOut: 16, error: Self.timedOut))
  }

  @Test func aPlayerThatStoppedAnsweringIsGivenUpOn() async throws {
    let queue = FakeQueue()
    queue.faults = Dictionary(uniqueKeysWithValues: (2...100).map { ($0, (Self.timedOut, false)) })
    let outcome = try await filler(queue).fill(Self.items(160), knownLength: 0, required: 1)
    #expect(queue.calls.count == 1 + 3 * 2)
    #expect(outcome == QueueFillOutcome(added: 16, leftOut: 144, error: Self.timedOut))
  }

  @Test func insertedBatchesFollowEachOtherAndCloseUpOverAFailedOne() async throws {
    let queue = FakeQueue()
    queue.tracks = ["a", "b", "c"]
    let fault = SonosError.fault(SoapFault(httpStatus: 500, upnpErrorCode: 402), action: "AddMultipleURIsToQueue")
    queue.faults = [2: (fault, false)]
    let outcome = try await filler(queue).fill(Self.items(40), position: 2, required: 1)
    #expect(queue.calls.map(\.position) == [2, 18, 18])
    let ids = Self.items(40).map(\.itemID)
    #expect(queue.tracks == ["a"] + ids.prefix(16) + ids.suffix(8) + ["b", "c"])
    #expect(outcome == QueueFillOutcome(added: 24, leftOut: 16, error: fault))
  }

  /// The report on Reddit: an album whose library songs carry a catalog id the player cannot find
  /// failed whole, with "AddMultipleURIsToQueue failed: UPnP error 800".
  @Test func aSongThePlayerCannotFindIsLeftOutAndTheRestPlays() async throws {
    let queue = FakeQueue()
    queue.unknownIDs = ["5"]
    var filler = filler(queue)
    var startedAt: [Int] = []
    filler.requiredAreIn = { startedAt.append($0) }
    let items = Self.items(21)
    let outcome = try await filler.fill(items, knownLength: 0, required: 1)
    #expect(queue.tracks == items.map(\.itemID).filter { $0 != "5" })
    #expect(outcome == QueueFillOutcome(added: 20, refused: [items[4]]))
    #expect(outcome.refused.map(\.title) == ["Song 5"])
    #expect(startedAt == [1])
    // 1–16 refused, 1–8 refused, 1–4 in, 5–8 refused, 5–6 refused, 5 refused, 6, 7–8, 9–16, 17–21.
    #expect(queue.calls.map(\.count) == [16, 8, 4, 4, 2, 1, 1, 2, 8, 5])
  }

  @Test func refusedSongsBeforeTheStartMoveItBack() async throws {
    let queue = FakeQueue()
    queue.unknownIDs = ["2", "3"]
    var filler = filler(queue)
    var startedAt: [Int] = []
    filler.requiredAreIn = { startedAt.append($0) }
    let outcome = try await filler.fill(Self.items(20), knownLength: 0, required: 10)
    #expect(startedAt == [8])
    #expect(queue.tracks[7] == "10")
    #expect(outcome.refused.map(\.itemID) == ["2", "3"])
  }

  @Test func whenTheStartIsRefusedPlaybackStartsAtTheNextSong() async throws {
    let queue = FakeQueue()
    queue.unknownIDs = ["16", "17"]
    var filler = filler(queue)
    var startedAt: [Int] = []
    filler.requiredAreIn = { startedAt.append($0) }
    let outcome = try await filler.fill(Self.items(20), knownLength: 0, required: 16)
    #expect(startedAt == [16])
    #expect(queue.tracks[15] == "18")
    #expect(outcome.added == 18)
  }

  @Test func whenTheStartAndAllAfterAreRefusedPlaybackStartsAtTheLastSongIn() async throws {
    let queue = FakeQueue()
    queue.unknownIDs = ["4", "5"]
    var filler = filler(queue)
    var startedAt: [Int] = []
    filler.requiredAreIn = { startedAt.append($0) }
    let outcome = try await filler.fill(Self.items(5), knownLength: 0, required: 4)
    #expect(startedAt == [3])
    #expect(outcome.added == 3)
  }

  @Test func whenEverySongIsRefusedNothingStartsAndNothingThrows() async throws {
    let queue = FakeQueue()
    queue.unknownIDs = ["1", "2", "3"]
    var filler = filler(queue)
    var started = false
    filler.requiredAreIn = { _ in started = true }
    let items = Self.items(3)
    let outcome = try await filler.fill(items, knownLength: 0, required: 1)
    #expect(!started)
    #expect(outcome == QueueFillOutcome(refused: items))
  }

  /// What an account that cannot see the catalog looks like: every song refused. The fill stops
  /// after four rather than trying every song of a long playlist one by one.
  @Test func whenTheFirstSongsAreAllRefusedTheFillStops() async throws {
    let queue = FakeQueue()
    let items = Self.items(50)
    queue.unknownIDs = Set(items.map(\.itemID))
    var filler = filler(queue)
    var started = false
    filler.requiredAreIn = { _ in started = true }
    let outcome = try await filler.fill(items, knownLength: 0, required: 1)
    #expect(queue.calls.map(\.count) == [16, 8, 4, 2, 1, 1, 2, 1, 1])
    #expect(!started)
    #expect(outcome == QueueFillOutcome(refused: Array(items.prefix(4)), stoppedOnRefusals: true))
  }

  @Test func refusalsAfterASongWentInDoNotStopTheFill() async throws {
    let queue = FakeQueue()
    let items = Self.items(10)
    queue.unknownIDs = Set(items.dropFirst().map(\.itemID))
    let outcome = try await filler(queue).fill(items, knownLength: 0, required: 1)
    #expect(queue.tracks == ["1"])
    #expect(outcome.refused.count == 9)
    #expect(!outcome.stoppedOnRefusals)
  }

  @Test func refusedSongsInAnInsertedBatchCloseUp() async throws {
    let queue = FakeQueue()
    queue.tracks = ["a", "b"]
    queue.unknownIDs = ["3"]
    let outcome = try await filler(queue).fill(Self.items(6), position: 2, required: 1)
    #expect(queue.tracks == ["a", "1", "2", "4", "5", "6", "b"])
    #expect(outcome.added == 5)
  }

  @Test func aFillReplacedMidwayStops() async throws {
    let queue = FakeQueue()
    var filler = filler(queue)
    var current = true
    filler.isCurrent = { current }
    filler.didAdd = { if queue.calls.count == 2 { current = false } }
    let outcome = try await filler.fill(Self.items(64), knownLength: 0, required: 1)
    #expect(queue.calls.count == 2)
    #expect(outcome == QueueFillOutcome(added: 32, wasSuperseded: true))
  }

  @Test func aLateAnswerIsOnlyAssumedWhereTheBatchWentIsKnown() {
    #expect(QueueFiller.lateAnswer(batch: 16, position: 0, asNext: false, before: 16, after: 32)
      == QueueAddResult(firstTrackNumberEnqueued: 17, numberOfTracksAdded: 16, newQueueLength: 32))
    #expect(QueueFiller.lateAnswer(batch: 16, position: 5, asNext: true, before: 16, after: 32)
      == QueueAddResult(firstTrackNumberEnqueued: 5, numberOfTracksAdded: 16, newQueueLength: 32))
    #expect(QueueFiller.lateAnswer(batch: 16, position: 0, asNext: false, before: 16, after: 16) == nil)
    #expect(QueueFiller.lateAnswer(batch: 16, position: 0, asNext: false, before: nil, after: 32) == nil)
    #expect(QueueFiller.lateAnswer(batch: 16, position: 0, asNext: true, before: 16, after: 32) == nil)
  }
}

/// The calls reported to the journal a host app's diagnostics read.
extension QueueFillerTests {
  /// What a host app's diagnostics show: each call, with its try and what it met.
  @Test func everyCallIsReportedWithItsTryAndWhatItMet() async throws {
    let queue = FakeQueue()
    queue.faults = [2: (Self.timedOut, false), 4: (Self.timedOut, true)]
    var filler = filler(queue)
    var calls: [QueueFillRecord.Call] = []
    filler.didCall = { calls.append($0) }
    _ = try await filler.fill(Self.items(40), knownLength: 0, required: 1)
    #expect(calls.map(\.label) == ["Batch 1/3", "Batch 2/3", "Batch 2/3", "Batch 3/3"])
    #expect(calls.map(\.attempt) == [1, 1, 2, 1])
    #expect(calls.map(\.count) == [16, 16, 16, 8])
    #expect(calls.map(\.error) == [nil, Self.timedOut, nil, Self.timedOut])
    #expect(calls.map(\.answeredLate) == [false, false, false, true])
    #expect(calls.map(\.sentAfter) == calls.map(\.sentAfter).sorted())
  }

  @Test func refusedHalvesAreReportedByTheirItems() async throws {
    let queue = FakeQueue()
    queue.unknownIDs = ["2"]
    var filler = filler(queue)
    var calls: [QueueFillRecord.Call] = []
    filler.didCall = { calls.append($0) }
    _ = try await filler.fill(Self.items(4), knownLength: 0, required: 1)
    #expect(calls.map(\.label) == [
      "Batch 1/1", "Batch 1/1, items 1–2", "Batch 1/1, item 1", "Batch 1/1, item 2", "Batch 1/1, items 3–4"
    ])
    #expect(calls.map { $0.error == nil } == [false, false, true, false, true])
  }
}

struct SessionBatchingTests {
  @Test func sixteenItemsPerCall() {
    let items = (1...35).map { EnqueueItem(uri: "song%3a\($0)", metadata: "", itemID: "\($0)") }
    let batches = SonosGroupSession.batches(of: items)
    #expect(batches.map(\.count) == [16, 16, 3])
    #expect(SonosGroupSession.batches(of: []).isEmpty)
  }
}

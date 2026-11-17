import Foundation
import Testing
@testable import AmusoKit

/// The last few queue fills, kept for a host app's diagnostics.
@MainActor
struct QueueFillJournalTests {
  private static let call = QueueFillRecord.Call(
    label: "Batch 1/1", count: 3, attempt: 1, sentAfter: .zero, duration: .milliseconds(40))

  @Test func onlyTheLastFillsAreKept() {
    let journal = QueueFillJournal(limit: 2)
    let first = journal.begin(room: "Office", kind: .add(asNext: false), itemCount: 1)
    let second = journal.begin(room: "Office", kind: .add(asNext: true), itemCount: 2)
    let third = journal.begin(room: "Kitchen", kind: .replace(startIndex: 1, playMode: .normal), itemCount: 3)
    #expect(journal.fills.map(\.id) == [second, third])
    // A fill dropped while it ran is not brought back by its end.
    journal.record(Self.call, in: first)
    journal.end(first, .finished(QueueFillOutcome(added: 1)), after: .seconds(1))
    #expect(journal.fills.map(\.id) == [second, third])
  }

  @Test func callsAndTheEndGoToTheirFill() {
    let journal = QueueFillJournal()
    let first = journal.begin(room: "Office", kind: .add(asNext: false), itemCount: 3)
    let second = journal.begin(room: "Office", kind: .add(asNext: false), itemCount: 3)
    journal.record(Self.call, in: first)
    journal.end(first, .finished(QueueFillOutcome(added: 3)), after: .seconds(1))
    #expect(journal.fills[0].calls == [Self.call])
    #expect(journal.fills[0].status == .finished(QueueFillOutcome(added: 3)))
    #expect(journal.fills[0].duration == .seconds(1))
    #expect(journal.fills[1].id == second)
    #expect(journal.fills[1].calls.isEmpty)
    #expect(journal.fills[1].status == .running)
    #expect(journal.fills[1].duration == nil)
  }
}

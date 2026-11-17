import Foundation
import Synchronization
import Testing
@testable import AmusoKit

/// A player that takes every AVTransport command, by host, so that the tests in parallel each
/// have theirs, and records the actions asked, with the play mode of each `SetPlayMode` and the
/// track of each `Seek`.
nonisolated private final class RecordingPlayer: URLProtocol {
  static let asked = Mutex<[String: [String]]>([:])

  static func actions(of host: String) -> [String] {
    asked.withLock { $0[host] ?? [] }
  }

  override static func canInit(with request: URLRequest) -> Bool { true }
  override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let host = request.url?.host() ?? ""
    let header = request.value(forHTTPHeaderField: "SOAPACTION") ?? ""
    let action = header.split(separator: "#").last.map { String($0).replacing("\"", with: "") } ?? ""
    var entry = action
    let body = Self.body(of: request)
    if action == "SetPlayMode", let mode = Self.value(of: "NewPlayMode", in: body) {
      entry += " \(mode)"
    } else if action == "Seek", let target = Self.value(of: "Target", in: body) {
      entry += " \(target)"
    }
    Self.asked.withLock { $0[host, default: []].append(entry) }
    let answer = Self.answer(to: action)
    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(answer.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}

  /// An empty answer, but for `AddMultipleURIsToQueue`, which answers as the captured one does:
  /// three items in, from the first.
  private static func answer(to action: String) -> String {
    let values = action == "AddMultipleURIsToQueue"
      ? "<FirstTrackNumberEnqueued>1</FirstTrackNumberEnqueued><NumTracksAdded>3</NumTracksAdded>"
        + "<NewQueueLength>3</NewQueueLength><NewUpdateID>17</NewUpdateID>"
      : ""
    return """
      <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" \
      s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>\
      <u:\(action)Response xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">\(values)</u:\(action)Response>\
      </s:Body></s:Envelope>
      """
  }

  /// The request's body, which reaches a protocol as a stream.
  private static func body(of request: URLRequest) -> String {
    if let data = request.httpBody {
      return String(decoding: data, as: UTF8.self)
    }
    guard let stream = request.httpBodyStream else { return "" }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
      let read = stream.read(&buffer, maxLength: buffer.count)
      guard read > 0 else { break }
      data.append(buffer, count: read)
    }
    return String(decoding: data, as: UTF8.self)
  }

  private static func value(of element: String, in body: String) -> String? {
    guard let start = body.range(of: "<\(element)>"),
          let end = body.range(of: "</\(element)>", range: start.upperBound..<body.endIndex) else { return nil }
    return String(body[start.upperBound..<end.lowerBound])
  }
}

/// A queue replaced while the player is still in the last one's shuffle: the play mode asked for
/// is the one it starts in, from the track asked for.
@MainActor
struct SonosGroupSessionReplaceQueueTests {
  private func session(host: String) throws -> SonosGroupSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [RecordingPlayer.self]
    let player = URLSession(configuration: configuration)
    let client = SoapClient(session: player, longSession: player)
    let endpoint = try #require(PlayerEndpoint(host: host))
    let speaker = Player(uuid: "RINCON_TEST", roomName: "Office", endpoint: endpoint)
    let group = ZoneGroup(id: "RINCON_TEST:1", coordinatorUUID: "RINCON_TEST", members: [speaker])
    return SonosGroupSession(group: group, client: client, gena: GenaClient(), listener: nil)
  }

  /// The fixture's player takes three.
  private let items = (1...3).map {
    EnqueueItem(uri: "song%3a\($0)", metadata: "", itemID: "\($0)", title: "Song \($0)")
  }

  /// The commands from the queue's first item in: what `replaceQueue` asks once the queue is clear.
  private func commands(of host: String) -> [String] {
    Array(RecordingPlayer.actions(of: host).drop { $0 != "AddMultipleURIsToQueue" }.dropFirst())
  }

  /// From the first track too: on the Era 300 pair, a queue replaced after a shuffled one played
  /// from the track number the shuffled one was at, without a seek.
  @Test func anUnshuffledQueueLeavesShuffleAndSeeksToTheFirstTrack() async throws {
    let host = "10.255.1.1"
    let session = try session(host: host)
    session.transport.playMode = .shuffleNoRepeat
    let outcome = try await session.replaceQueue(with: items, playMode: .normal)
    #expect(outcome.added == 3)
    #expect(commands(of: host) == ["SetAVTransportURI", "SetPlayMode NORMAL", "Seek 1", "Play"])
    #expect(session.transport.playMode == .normal)
  }

  @Test func aShuffledQueueStartsWhereAskedThenShuffles() async throws {
    let host = "10.255.1.2"
    let session = try session(host: host)
    let outcome = try await session.replaceQueue(with: items, startIndex: 3, playMode: .shuffleNoRepeat)
    #expect(outcome.added == 3)
    #expect(commands(of: host) == [
      "SetAVTransportURI", "SetPlayMode NORMAL", "Seek 3", "Play", "SetPlayMode SHUFFLE_NOREPEAT"
    ])
    #expect(session.transport.playMode == .shuffleNoRepeat)
  }

  /// What a host app's diagnostics report: the fill, its call, and how it ended.
  @Test func aFillIsRecordedInTheJournal() async throws {
    let host = "10.255.1.4"
    let session = try session(host: host)
    let outcome = try await session.replaceQueue(with: items, startIndex: 2, playMode: .shuffleNoRepeat)
    let fill = try #require(session.fillJournal.fills.last)
    #expect(fill.room == "Office")
    #expect(fill.kind == .replace(startIndex: 2, playMode: .shuffleNoRepeat))
    #expect(fill.itemCount == 3)
    #expect(fill.calls.map(\.label) == ["Batch 1/1"])
    #expect(fill.calls.first?.error == nil)
    #expect(fill.status == .finished(outcome))
    #expect(fill.duration != nil)
  }

  @Test func aFillThatThrowsIsRecordedAsFailed() async throws {
    let endpoint = try #require(PlayerEndpoint(host: "10.255.1.5"))
    let speaker = Player(uuid: "RINCON_TEST", roomName: "Office", endpoint: endpoint)
    // A coordinator the topology no longer has.
    let group = ZoneGroup(id: "RINCON_GONE:1", coordinatorUUID: "RINCON_GONE", members: [speaker])
    let session = SonosGroupSession(group: group, client: SoapClient(), gena: GenaClient(), listener: nil)
    await #expect(throws: SonosError.notFound("coordinator")) {
      try await session.enqueue(items, asNext: true)
    }
    let fill = try #require(session.fillJournal.fills.last)
    #expect(fill.kind == .add(asNext: true))
    #expect(fill.calls.isEmpty)
    #expect(fill.status == .failed(.notFound("coordinator")))
  }

  /// What the status indicator and Up Next show while a queue fills: how far it has got, then
  /// nothing once it is done.
  @Test func aFillsProgressIsGoneOnceItIsDone() async throws {
    let host = "10.255.1.6"
    let session = try session(host: host)
    #expect(session.queueFillProgress == nil)
    let outcome = try await session.replaceQueue(with: items)
    #expect(outcome.added == 3)
    #expect(session.queueFillProgress == nil)
  }

  /// A queue replaced stops the fills under way, whose songs then no longer count; Play Next and
  /// Play Last add theirs to the total.
  @Test func aReplacedQueueDropsTheProgressOfTheFillsItStopped() throws {
    let session = try session(host: "10.255.1.7")
    let first = session.beginQueueFill(replacing: true, count: 500)
    session.progress(first, processed: 96)
    #expect(session.queueFillProgress == QueueFillProgress(processed: 96, total: 500))
    let added = session.beginQueueFill(replacing: false, count: 12)
    #expect(session.queueFillProgress == QueueFillProgress(processed: 96, total: 512))
    session.endQueueFill(added)
    let second = session.beginQueueFill(replacing: true, count: 40)
    #expect(!session.isCurrent(first))
    session.progress(first, processed: 112)
    #expect(session.queueFillProgress == QueueFillProgress(processed: 0, total: 40))
    session.endQueueFill(first)
    session.progress(second, processed: 16)
    #expect(session.queueFillProgress?.fraction == 0.4)
    session.endQueueFill(second)
    #expect(session.queueFillProgress == nil)
  }

  @Test func repeatIsKeptFromTheStart() async throws {
    let host = "10.255.1.3"
    let session = try session(host: host)
    _ = try await session.replaceQueue(with: items, playMode: .shuffle)
    #expect(commands(of: host) == [
      "SetAVTransportURI", "SetPlayMode REPEAT_ALL", "Seek 1", "Play", "SetPlayMode SHUFFLE"
    ])
  }
}

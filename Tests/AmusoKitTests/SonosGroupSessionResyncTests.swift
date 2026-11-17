import Foundation
import Synchronization
import Testing
@testable import AmusoKit

/// Answers SOAP requests with the captured fixtures' bodies, by host, so that the tests in
/// parallel each have their player.
nonisolated private final class FixturePlayer: URLProtocol {
  /// By host: the fixture answering each action, and the actions asked, in order.
  static let players = Mutex<[String: (answers: [String: String], asked: [String])]>([:])

  static func serve(host: String, answers: [String: String]) {
    players.withLock { $0[host] = (answers, []) }
  }

  static func asked(by host: String) -> [String] {
    players.withLock { $0[host]?.asked ?? [] }
  }

  override static func canInit(with request: URLRequest) -> Bool { true }
  override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let host = request.url?.host() ?? ""
    let header = request.value(forHTTPHeaderField: "SOAPACTION") ?? ""
    let action = header.split(separator: "#").last.map { String($0).replacing("\"", with: "") } ?? ""
    let answer = Self.players.withLock { players -> String? in
      players[host]?.asked.append(action)
      return players[host]?.answers[action]
    }
    let body = answer ?? ""
    let status = answer == nil ? 500 : 200
    let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(body.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

@MainActor
struct SonosGroupSessionResyncTests {
  private func session(host: String) throws -> SonosGroupSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [FixturePlayer.self]
    let client = SoapClient(session: URLSession(configuration: configuration))
    let endpoint = try #require(PlayerEndpoint(host: host))
    let player = Player(uuid: "RINCON_TEST", roomName: "Office", endpoint: endpoint)
    let group = ZoneGroup(id: "RINCON_TEST:1", coordinatorUUID: "RINCON_TEST", members: [player])
    return SonosGroupSession(group: group, client: client, gena: GenaClient(), listener: nil)
  }

  /// The player's answers, the captured responses of a paused player, by action.
  private func answers() throws -> [String: String] {
    [
      "GetTransportInfo": try Fixtures.string("GetTransportInfo.xml"),
      "GetMediaInfo": try Fixtures.string("GetMediaInfo.xml"),
      "GetPositionInfo": try Fixtures.string("GetPositionInfo-catalog-song.xml"),
      // No capture of this one; the play mode is all the session reads of it.
      "GetTransportSettings": """
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" \
        s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>\
        <u:GetTransportSettingsResponse xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">\
        <PlayMode>NORMAL</PlayMode><RecQualityMode>NOT_IMPLEMENTED</RecQualityMode>\
        </u:GetTransportSettingsResponse></s:Body></s:Envelope>
        """
    ]
  }

  /// The room was paused from elsewhere and the event never came: the periodic read sees it, so
  /// that the app stops believing the room plays (and, on iOS, stops its silence).
  @Test func aPauseWhoseEventWasMissedIsSeenByThePeriodicRead() async throws {
    let host = "10.255.0.1"
    FixturePlayer.serve(host: host, answers: try answers())
    let session = try session(host: host)
    session.transport.state = .playing
    await session.resyncWhilePlaying()
    // The fixture's player is paused.
    #expect(session.transport.state == .paused)
    #expect(FixturePlayer.asked(by: host).first == "GetTransportInfo")
    #expect(FixturePlayer.asked(by: host).contains("GetMediaInfo"))
  }

  @Test func whenTheStateHoldsOnlyThePositionIsReadAgain() async throws {
    let host = "10.255.0.2"
    FixturePlayer.serve(host: host, answers: try answers())
    let session = try session(host: host)
    session.transport.state = .paused
    await session.resyncWhilePlaying()
    #expect(FixturePlayer.asked(by: host) == ["GetTransportInfo", "GetPositionInfo"])
    #expect(session.transport.position != nil)
  }

  @Test func pollingSlowsDownInTheBackground() throws {
    let session = try session(host: "10.255.0.3")
    #expect(session.pollInterval == SonosGroupSession.foregroundPollInterval)
    session.isInBackground = true
    #expect(session.pollInterval == SonosGroupSession.backgroundPollInterval)
    #expect(SonosGroupSession.backgroundPollInterval > SonosGroupSession.foregroundPollInterval)
  }
}

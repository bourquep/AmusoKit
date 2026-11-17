import Foundation
import Testing
@testable import AmusoKit

struct HouseholdSearchTests {
  nonisolated private static let live = PlayerEndpoint(host: "192.168.1.10")!
  nonisolated private static let otherLive = PlayerEndpoint(host: "192.168.1.11")!
  nonisolated private static let unplugged = PlayerEndpoint(host: "192.168.1.90")!
  nonisolated private static let asleep = PlayerEndpoint(host: "192.168.1.91")!

  private static func household() throws -> Household {
    let response = try SoapResponse.parse(
      try Fixtures.data("GetZoneGroupState.xml"),
      status: 200,
      action: SoapAction(service: .zoneGroupTopology, name: "GetZoneGroupState")
    )
    return try ZoneGroupTopologyService.parse(zoneGroupState: try response.require("ZoneGroupState"))
  }

  /// A player that never answers: it waits until the search no longer needs it.
  nonisolated private static func silent() async throws -> Household {
    try await Task.sleep(for: .seconds(30))
    throw SonosError.invalidResponse("should have been cancelled")
  }

  @Test func playersThatDoNotAnswerHoldUpNoOther() async throws {
    let household = try Self.household()
    let clock = ContinuousClock()
    let started = clock.now
    let outcome = await HouseholdSearch.first(
      known: [Self.unplugged, Self.asleep, Self.live],
      stagger: .milliseconds(10),
      discover: { [] },
      household: { endpoint in
        endpoint == Self.live ? household : try await Self.silent()
      }
    )
    #expect(outcome.endpoint == Self.live)
    #expect(outcome.household == household)
    #expect(started.duration(to: clock.now) < .seconds(5))
  }

  @Test func bonjourPlayersAreAskedWhenNoKnownOneAnswers() async throws {
    let household = try Self.household()
    let outcome = await HouseholdSearch.first(
      known: [Self.unplugged],
      stagger: .milliseconds(10),
      discover: { [Self.unplugged, Self.live] },
      household: { endpoint in
        guard endpoint == Self.live else { throw SonosError.unreachable(endpoint, reason: "down") }
        return household
      }
    )
    #expect(outcome.endpoint == Self.live)
    #expect(outcome.household == household)
  }

  @Test func anEmptyHouseholdIsNotAnAnswer() async throws {
    let household = try Self.household()
    let outcome = await HouseholdSearch.first(
      known: [Self.live, Self.otherLive],
      stagger: .milliseconds(10),
      discover: { [] },
      household: { endpoint in
        endpoint == Self.live ? Household(groups: []) : household
      }
    )
    #expect(outcome.endpoint == Self.otherLive)
  }

  @Test func nothingFoundKeepsTheLastError() async {
    let outcome = await HouseholdSearch.first(
      known: [Self.unplugged],
      stagger: .milliseconds(10),
      discover: { [] },
      household: { endpoint in throw SonosError.unreachable(endpoint, reason: "down") }
    )
    #expect(outcome.household == nil)
    #expect(outcome.lastError == .unreachable(Self.unplugged, reason: "down"))
  }
}

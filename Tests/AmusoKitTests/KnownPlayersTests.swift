import Foundation
import Testing
@testable import AmusoKit

struct KnownPlayersTests {
  @Test func remembersAHouseholdMostRecentFirst() throws {
    let response = try SoapResponse.parse(
      try Fixtures.data("GetZoneGroupState.xml"),
      status: 200,
      action: SoapAction(service: .zoneGroupTopology, name: "GetZoneGroupState")
    )
    let household = try ZoneGroupTopologyService.parse(zoneGroupState: try response.require("ZoneGroupState"))
    var known = KnownPlayers()
    known.remember(household, now: Date(timeIntervalSince1970: 1000))
    #expect(known.players.count == 5)
    #expect(known.endpoint(for: "RINCON_000E58A0000101400")?.host == "192.168.1.10")
    known.players["RINCON_000E58A0000401400"]?.lastSeen = Date(timeIntervalSince1970: 2000)
    #expect(known.endpoints.first?.host == "192.168.1.126")
    let data = try JSONEncoder().encode(known)
    #expect(try JSONDecoder().decode(KnownPlayers.self, from: data) == known)
  }

  @Test func forgetsThePlayersTheHouseholdNoLongerLists() throws {
    let response = try SoapResponse.parse(
      try Fixtures.data("GetZoneGroupState.xml"),
      status: 200,
      action: SoapAction(service: .zoneGroupTopology, name: "GetZoneGroupState")
    )
    let household = try ZoneGroupTopologyService.parse(zoneGroupState: try response.require("ZoneGroupState"))
    var known = KnownPlayers(players: [
      "RINCON_UNPLUGGED01400": .init(
        host: "192.168.1.90", roomName: "Garage", lastSeen: Date(timeIntervalSince1970: 3000))
    ])
    known.remember(household, now: Date(timeIntervalSince1970: 1000))
    #expect(known.players.count == 5)
    #expect(known.endpoint(for: "RINCON_UNPLUGGED01400") == nil)
    #expect(!known.endpoints.contains { $0.host == "192.168.1.90" })
  }

  @Test func anEmptyHouseholdForgetsNoOne() {
    var known = KnownPlayers(players: [
      "RINCON_A": .init(host: "192.168.1.10", roomName: "Living Room", lastSeen: Date(timeIntervalSince1970: 1000))
    ])
    known.remember(Household(groups: []))
    #expect(known.players.count == 1)
  }
}

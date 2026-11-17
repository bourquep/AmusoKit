import Foundation
import Testing
@testable import AmusoKit

struct ZoneGroupTopologyTests {
  private func household() throws -> Household {
    let response = try SoapResponse.parse(
      try Fixtures.data("GetZoneGroupState.xml"),
      status: 200,
      action: SoapAction(service: .zoneGroupTopology, name: "GetZoneGroupState")
    )
    return try ZoneGroupTopologyService.parse(zoneGroupState: try response.require("ZoneGroupState"))
  }

  @Test func twoGroupsWithTheirCoordinators() throws {
    let household = try household()
    #expect(household.groups.count == 2)
    #expect(household.groups.map(\.name) == ["Véranda", "Living Room"])
    #expect(household.groups[0].coordinatorUUID == "RINCON_000E58A0000101400")
    #expect(household.groups[0].coordinator?.endpoint.host == "192.168.1.10")
  }

  @Test func stereoPairAndSubAreInvisibleMembers() throws {
    let sejour = try #require(try household().group(named: "véranda"))
    #expect(sejour.members.count == 3)
    #expect(sejour.visibleMembers.map(\.uuid) == ["RINCON_000E58A0000101400"])
    #expect(sejour.members.filter(\.isInvisible).count == 2)
  }

  @Test func groupsAreFoundByRoomNameAndByUUID() throws {
    let household = try household()
    #expect(household.group(named: "LIVING ROOM")?.coordinator?.roomName == "Living Room")
    #expect(household.group(named: "RINCON_000E58A0000501400")?.name == "Living Room")
    #expect(household.group(named: "Kitchen") == nil)
  }

  @Test func atmosCapabilityComesFromTheDeviceDescription() throws {
    var household = try household()
    #expect(household.groups[0].isAtmosCapable == false)
    let description = try DeviceDescription.parse(try Fixtures.data("DeviceDescription-Era300.xml"))
    household.groups[0].members[0].deviceDescription = description
    #expect(household.groups[0].isAtmosCapable)
  }
}

import Foundation

/// The household as any one player describes it.
nonisolated public struct ZoneGroupTopologyService: Sendable {
  public let client: SoapClient
  public let endpoint: PlayerEndpoint

  public init(client: SoapClient, endpoint: PlayerEndpoint) {
    self.client = client
    self.endpoint = endpoint
  }

  /// The raw `ZoneGroupState` document.
  public func getZoneGroupStateXML() async throws -> String {
    try await client.call(
      SoapAction(service: .zoneGroupTopology, name: "GetZoneGroupState"),
      on: endpoint
    ).require("ZoneGroupState")
  }

  /// The household, with each player's device description when `fetchDescriptions` is set.
  public func household(fetchDescriptions: Bool = false) async throws -> Household {
    let household = try Self.parse(zoneGroupState: try await getZoneGroupStateXML())
    guard fetchDescriptions else { return household }
    return await Self.describing(household, session: client.session)
  }

  /// The household with each player's device description, fetched all at once. A player that
  /// does not answer within `timeout` is left without one, rather than holding up the others.
  public static func describing(
    _ household: Household, session: URLSession, timeout: Duration = .seconds(2)
  ) async -> Household {
    let descriptions = await withTaskGroup(of: (String, DeviceDescription?).self) { group in
      for player in household.players {
        group.addTask {
          (player.uuid, try? await DeviceDescription.fetch(from: player.endpoint, session: session, timeout: timeout))
        }
      }
      var result: [String: DeviceDescription] = [:]
      for await (uuid, description) in group {
        result[uuid] = description
      }
      return result
    }
    var described = household
    for groupIndex in described.groups.indices {
      for memberIndex in described.groups[groupIndex].members.indices {
        let uuid = described.groups[groupIndex].members[memberIndex].uuid
        described.groups[groupIndex].members[memberIndex].deviceDescription = descriptions[uuid]
      }
    }
    return described
  }

  public static func parse(zoneGroupState xml: String) throws -> Household {
    let root = try XMLTree.parse(xml)
    let groups = root.all("ZoneGroup").compactMap { node -> ZoneGroup? in
      guard let coordinator = node.attributes["Coordinator"] else { return nil }
      var members: [Player] = []
      for member in node.children where member.name == "ZoneGroupMember" {
        if let player = Self.player(from: member) {
          members.append(player)
        }
        for satellite in member.children where satellite.name == "Satellite" {
          if var player = Self.player(from: satellite) {
            player.isInvisible = true
            members.append(player)
          }
        }
      }
      guard !members.isEmpty else { return nil }
      return ZoneGroup(id: node.attributes["ID"] ?? coordinator, coordinatorUUID: coordinator, members: members)
    }
    return Household(groups: groups)
  }

  private static func player(from node: XMLNode) -> Player? {
    guard let uuid = node.attributes["UUID"],
      let location = node.attributes["Location"].flatMap(URL.init(string:)),
      let endpoint = PlayerEndpoint(url: location)
    else { return nil }
    return Player(
      uuid: uuid,
      roomName: node.attributes["ZoneName"] ?? "",
      endpoint: endpoint,
      isInvisible: node.attributes["Invisible"] == "1" || node.attributes["IsZoneBridge"] == "1"
    )
  }
}

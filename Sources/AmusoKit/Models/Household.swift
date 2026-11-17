import Foundation

/// Every player on the network, grouped as the Sonos app shows them.
nonisolated public struct Household: Hashable, Sendable {
  public var groups: [ZoneGroup]

  public init(groups: [ZoneGroup]) {
    self.groups = groups
  }

  public var players: [Player] {
    groups.flatMap(\.members)
  }

  public func group(containing uuid: String) -> ZoneGroup? {
    groups.first { group in group.members.contains { $0.uuid == uuid } }
  }

  /// The group whose name, or one of whose rooms, matches `name` (case and diacritics aside), or
  /// the group containing the player with that `RINCON_…` identifier.
  public func group(named name: String) -> ZoneGroup? {
    if let byUUID = group(containing: name) {
      return byUUID
    }
    return groups.first { group in
      group.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        || group.members.contains { $0.roomName.localizedCaseInsensitiveCompare(name) == .orderedSame }
    }
  }
}

import Foundation

/// Players that play together, led by their coordinator.
nonisolated public struct ZoneGroup: Hashable, Sendable, Identifiable {
  public var id: String
  public var coordinatorUUID: String
  public var members: [Player]

  public init(id: String, coordinatorUUID: String, members: [Player]) {
    self.id = id
    self.coordinatorUUID = coordinatorUUID
    self.members = members
  }

  public var coordinator: Player? {
    members.first { $0.uuid == coordinatorUUID }
  }

  /// The members the Sonos app shows: the coordinator first, then the others by room name.
  public var visibleMembers: [Player] {
    let visible = members.filter { !$0.isInvisible }
    return visible.sorted { lhs, rhs in
      if lhs.uuid == coordinatorUUID { return true }
      if rhs.uuid == coordinatorUUID { return false }
      return lhs.roomName.localizedStandardCompare(rhs.roomName) == .orderedAscending
    }
  }

  /// "Office", or "Office + Kitchen" for a group of rooms.
  public var name: String {
    visibleMembers.map(\.roomName).joined(separator: " + ")
  }

  /// `true` when every room in the group can render Dolby Atmos: Sonos drops a group to stereo
  /// otherwise.
  public var isAtmosCapable: Bool {
    let visible = visibleMembers
    return !visible.isEmpty && visible.allSatisfy(\.isAtmosCapable)
  }
}

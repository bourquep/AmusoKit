import Foundation

/// The players seen before, by UUID, so that reconnecting and App Intents do not wait on
/// discovery.
nonisolated public struct KnownPlayers: Sendable, Hashable, Codable {
  public struct Entry: Sendable, Hashable, Codable {
    public var host: String
    public var roomName: String
    public var lastSeen: Date

    public init(host: String, roomName: String, lastSeen: Date) {
      self.host = host
      self.roomName = roomName
      self.lastSeen = lastSeen
    }
  }

  public var players: [String: Entry] = [:]

  public init(players: [String: Entry] = [:]) {
    self.players = players
  }

  public var isEmpty: Bool { players.isEmpty }

  /// The endpoints to try first, most recently seen first.
  public var endpoints: [PlayerEndpoint] {
    players.values
      .sorted { $0.lastSeen > $1.lastSeen }
      .compactMap { PlayerEndpoint(host: $0.host) }
  }

  /// Keeps the household's players, and forgets the ones it no longer lists: a player unplugged,
  /// a portable one asleep, or one that left. Any player describes the whole household, so a
  /// forgotten one comes back with the next household that lists it, and none is left to be
  /// asked in vain at the next launch.
  public mutating func remember(_ household: Household, now: Date = .now) {
    // A topology that lists no one says nothing about who is still there.
    guard !household.players.isEmpty else { return }
    var remembered: [String: Entry] = [:]
    for player in household.players {
      remembered[player.uuid] = Entry(host: player.endpoint.host, roomName: player.roomName, lastSeen: now)
    }
    players = remembered
  }

  public func endpoint(for uuid: String) -> PlayerEndpoint? {
    players[uuid].flatMap { PlayerEndpoint(host: $0.host) }
  }
}

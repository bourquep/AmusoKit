import Foundation

/// One Sonos player (a zone), as the household's topology describes it.
nonisolated public struct Player: Hashable, Sendable, Identifiable {
  public var id: String { uuid }

  /// The player's `RINCON_…` identifier.
  public var uuid: String
  public var roomName: String
  public var endpoint: PlayerEndpoint
  /// `true` for the second speaker of a stereo pair, a Sub or surrounds: they follow their
  /// visible partner and take no commands of their own.
  public var isInvisible: Bool
  /// The player's device description, when it was fetched.
  public var deviceDescription: DeviceDescription?

  public init(
    uuid: String,
    roomName: String,
    endpoint: PlayerEndpoint,
    isInvisible: Bool = false,
    deviceDescription: DeviceDescription? = nil
  ) {
    self.uuid = uuid
    self.roomName = roomName
    self.endpoint = endpoint
    self.isInvisible = isInvisible
    self.deviceDescription = deviceDescription
  }

  public var modelName: String? { deviceDescription?.modelName }

  public var isAtmosCapable: Bool { AtmosCapability.isCapable(deviceDescription) }
}

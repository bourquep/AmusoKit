import Foundation

/// What `/xml/device_description.xml` says about a player.
nonisolated public struct DeviceDescription: Sendable, Hashable {
  public var friendlyName: String?
  public var roomName: String?
  public var modelName: String?
  public var modelNumber: String?
  public var softwareVersion: String?
  public var displayVersion: String?
  public var hardwareVersion: String?
  public var serialNumber: String?
  /// `uuid:RINCON_…`, without the `uuid:` prefix.
  public var uuid: String?

  public static let path = "/xml/device_description.xml"

  public init(
    friendlyName: String? = nil,
    roomName: String? = nil,
    modelName: String? = nil,
    modelNumber: String? = nil,
    softwareVersion: String? = nil,
    displayVersion: String? = nil,
    hardwareVersion: String? = nil,
    serialNumber: String? = nil,
    uuid: String? = nil
  ) {
    self.friendlyName = friendlyName
    self.roomName = roomName
    self.modelName = modelName
    self.modelNumber = modelNumber
    self.softwareVersion = softwareVersion
    self.displayVersion = displayVersion
    self.hardwareVersion = hardwareVersion
    self.serialNumber = serialNumber
    self.uuid = uuid
  }

  public static func fetch(
    from endpoint: PlayerEndpoint, session: URLSession, timeout: Duration? = nil
  ) async throws -> DeviceDescription {
    var request = URLRequest(url: endpoint.url(path: path))
    if let timeout {
      request.timeoutInterval = TimeInterval(timeout.components.seconds)
        + TimeInterval(timeout.components.attoseconds) / 1e18
    }
    let (data, _) = try await session.data(for: request)
    return try parse(data)
  }

  public static func parse(_ data: Data) throws -> DeviceDescription {
    let root = try XMLTree.parse(data)
    guard let device = root.first("device") else {
      throw SonosError.invalidResponse("device description without a device element")
    }
    return DeviceDescription(
      friendlyName: device.childText("friendlyName"),
      roomName: device.childText("roomName"),
      modelName: device.childText("modelName"),
      modelNumber: device.childText("modelNumber"),
      softwareVersion: device.childText("softwareVersion"),
      displayVersion: device.childText("displayVersion"),
      hardwareVersion: device.childText("hardwareVersion"),
      serialNumber: device.childText("serialNum"),
      uuid: device.childText("UDN").map { $0.replacing("uuid:", with: "") }
    )
  }
}

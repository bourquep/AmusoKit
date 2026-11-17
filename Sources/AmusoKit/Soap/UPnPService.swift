import Foundation

/// The UPnP services the app talks to, with their paths on every Sonos player.
nonisolated enum UPnPService: String, Sendable, CaseIterable {
  case avTransport = "AVTransport"
  case renderingControl = "RenderingControl"
  case groupRenderingControl = "GroupRenderingControl"
  case zoneGroupTopology = "ZoneGroupTopology"
  case contentDirectory = "ContentDirectory"
  case deviceProperties = "DeviceProperties"

  var serviceType: String {
    "urn:schemas-upnp-org:service:\(rawValue):1"
  }

  var controlPath: String {
    switch self {
    case .avTransport, .renderingControl, .groupRenderingControl:
      "/MediaRenderer/\(rawValue)/Control"
    case .contentDirectory:
      "/MediaServer/ContentDirectory/Control"
    case .zoneGroupTopology, .deviceProperties:
      "/\(rawValue)/Control"
    }
  }

  var eventPath: String {
    controlPath.replacing("/Control", with: "/Event")
  }
}

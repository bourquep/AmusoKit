import Foundation

/// A UPnP fault a player returned.
nonisolated public struct SoapFault: Error, Sendable, Hashable {
  public var httpStatus: Int
  public var upnpErrorCode: Int?
  public var upnpErrorDescription: String?

  public init(httpStatus: Int, upnpErrorCode: Int? = nil, upnpErrorDescription: String? = nil) {
    self.httpStatus = httpStatus
    self.upnpErrorCode = upnpErrorCode
    self.upnpErrorDescription = upnpErrorDescription
  }
}

nonisolated public enum SonosError: Error, Sendable, Hashable, CustomStringConvertible {
  /// The player answered 403: the household's Connection Security settings refuse UPnP.
  case upnpDisabled(PlayerEndpoint)
  /// No HTTP answer at all: wrong address, player off, or UPnP turned off on older firmware.
  case unreachable(PlayerEndpoint, reason: String)
  case fault(SoapFault, action: String)
  case invalidResponse(String)
  case notFound(String)

  public var description: String {
    switch self {
    case .upnpDisabled(let endpoint):
      "\(endpoint.host) refused the request (HTTP 403). "
        + "In the Sonos app, check System › Connection Security and turn UPnP on."
    case .unreachable(let endpoint, let reason):
      "\(endpoint.host):\(endpoint.port) did not answer: \(reason)"
    case .fault(let fault, let action):
      "\(action) failed: UPnP error \(fault.upnpErrorCode.map(String.init) ?? "?") "
        + "\(fault.upnpErrorDescription ?? "") (HTTP \(fault.httpStatus))"
    case .invalidResponse(let detail):
      "Unexpected answer from the player: \(detail)"
    case .notFound(let what):
      "Not found: \(what)"
    }
  }
}

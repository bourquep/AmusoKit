import Foundation

/// Where a Sonos player answers UPnP over HTTP: its address and port 1400.
nonisolated public struct PlayerEndpoint: Hashable, Sendable, Codable {
  public let host: String
  public let port: Int
  public let baseURL: URL

  public init?(host: String, port: Int = 1400) {
    var components = URLComponents()
    components.scheme = "http"
    components.host = host
    components.port = port
    guard let url = components.url else { return nil }
    self.host = host
    self.port = port
    self.baseURL = url
  }

  /// The endpoint behind a player's `Location` or device-description URL.
  public init?(url: URL) {
    guard let host = url.host() else { return nil }
    self.init(host: host, port: url.port ?? 1400)
  }

  public func url(path: String) -> URL {
    var trimmed = Substring(path)
    while trimmed.hasPrefix("/") {
      trimmed = trimmed.dropFirst()
    }
    return baseURL.appending(path: String(trimmed))
  }
}

import Foundation
import Network
import Synchronization

/// The address of this device that a player can reach, for the event callback.
nonisolated public enum LocalAddress {
  /// The local address of a connection to the player, which is on the right interface by
  /// construction; the first non-loopback IPv4 address otherwise.
  public static func reaching(_ endpoint: PlayerEndpoint, timeout: Duration = .seconds(3)) async -> String? {
    if let host = await localHost(connectingTo: endpoint, timeout: timeout) {
      return host
    }
    return firstIPv4Address()
  }

  static func localHost(connectingTo endpoint: PlayerEndpoint, timeout: Duration) async -> String? {
    let parameters = NWParameters.tcp
    if let ipOptions = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
      ipOptions.version = .v4
    }
    guard let port = NWEndpoint.Port(rawValue: UInt16(endpoint.port)) else { return nil }
    let connection = NWConnection(host: NWEndpoint.Host(endpoint.host), port: port, using: parameters)
    let box = ConnectionBox(connection)
    return await box.awaitLocalHost(timeout: timeout)
  }

  /// The first IPv4 address of an interface that is up and not loopback.
  public static func firstIPv4Address() -> String? {
    var addresses: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&addresses) == 0, let first = addresses else { return nil }
    defer { freeifaddrs(addresses) }
    var pointer: UnsafeMutablePointer<ifaddrs>? = first
    while let interface = pointer {
      defer { pointer = interface.pointee.ifa_next }
      let flags = Int32(interface.pointee.ifa_flags)
      guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
        let address = interface.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET)
      else { continue }
      var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      let length = socklen_t(address.pointee.sa_len)
      if getnameinfo(address, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
        // Up to the terminating NUL, as the deprecated `String(cString:)` read it.
        let bytes = host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
      }
    }
    return nil
  }
}

nonisolated private final class ConnectionBox: @unchecked Sendable {
  private let connection: NWConnection

  init(_ connection: NWConnection) {
    self.connection = connection
  }

  func awaitLocalHost(timeout: Duration) async -> String? {
    let resumed = Mutex(false)
    return await withCheckedContinuation { continuation in
      let finish: @Sendable (String?) -> Void = { [connection] host in
        let first = resumed.withLock { done in
          if done { return false }
          done = true
          return true
        }
        guard first else { return }
        connection.cancel()
        continuation.resume(returning: host)
      }
      connection.stateUpdateHandler = { [connection] state in
        switch state {
        case .ready:
          if case .hostPort(let host, _)? = connection.currentPath?.localEndpoint {
            switch host {
            case .ipv4(let address): finish("\(address)")
            case .ipv6(let address): finish("\(address)".split(separator: "%").first.map(String.init))
            case .name(let name, _): finish(name)
            @unknown default: finish(nil)
            }
          } else {
            finish(nil)
          }
        case .failed, .cancelled:
          finish(nil)
        default:
          break
        }
      }
      connection.start(queue: .global(qos: .userInitiated))
      Task {
        try? await Task.sleep(for: timeout)
        finish(nil)
      }
    }
  }
}

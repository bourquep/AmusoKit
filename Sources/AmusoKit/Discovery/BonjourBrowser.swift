import Foundation
import Network
import Synchronization

/// A `_sonos._tcp` service as Bonjour announces it.
nonisolated struct DiscoveredService: Sendable, Hashable {
  var name: String
  var type: String
  var domain: String
  var txt: [String: String]

  /// The device-description URL some firmwares put in the TXT record's `location`.
  var locationURL: URL? {
    guard let location = txt["location"], let url = URL(string: location), url.host() != nil else { return nil }
    return url
  }
}

/// Finds players over Bonjour, which needs no multicast entitlement on iOS.
nonisolated public enum BonjourBrowser {
  public static let serviceType = "_sonos._tcp"

  /// Browses for `timeout`, then returns everything announced.
  static func browse(timeout: Duration = .seconds(3)) async -> [DiscoveredService] {
    let found = Mutex<[String: DiscoveredService]>([:])
    let browser = NWBrowser(for: .bonjourWithTXTRecord(type: serviceType, domain: nil), using: .tcp)
    browser.browseResultsChangedHandler = { results, _ in
      var services: [String: DiscoveredService] = [:]
      for result in results {
        guard case .service(let name, let type, let domain, _) = result.endpoint else { continue }
        var txt: [String: String] = [:]
        if case .bonjour(let record) = result.metadata {
          txt = record.dictionary
        }
        services[name] = DiscoveredService(name: name, type: type, domain: domain, txt: txt)
      }
      found.withLock { $0 = services }
    }
    let states = Mutex<[String]>([])
    browser.stateUpdateHandler = { state in
      states.withLock { $0.append("\(state)") }
    }
    browser.start(queue: .global(qos: .userInitiated))
    try? await Task.sleep(for: timeout)
    browser.cancel()
    lastStates = states.withLock { $0 }
    return found.withLock { Array($0.values) }.sorted { $0.name < $1.name }
  }

  /// The states the last browse went through, for a log: `ready`, or `waiting(…)` with the
  /// reason the system gave.
  public static var lastStates: [String] {
    get { lastStatesStorage.withLock { $0 } }
    set { lastStatesStorage.withLock { $0 = newValue } }
  }

  private static let lastStatesStorage = Mutex<[String]>([])

  /// Resolves a service's IPv4 address by opening a connection to it.
  static func resolveHost(of service: DiscoveredService, timeout: Duration = .seconds(3)) async -> String? {
    let parameters = NWParameters.tcp
    if let ipOptions = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
      ipOptions.version = .v4
    }
    let endpoint = NWEndpoint.service(name: service.name, type: service.type, domain: service.domain, interface: nil)
    let connection = ConnectionBox(NWConnection(to: endpoint, using: parameters))
    // Cancelled, the connection goes to `.cancelled`, which finishes the resolution at once.
    return await withTaskCancellationHandler {
      await resolve(connection, timeout: timeout)
    } onCancel: {
      connection.cancel()
    }
  }

  private static func resolve(_ connection: ConnectionBox, timeout: Duration) async -> String? {
    let resumed = Mutex(false)
    return await withCheckedContinuation { continuation in
      let finish: @Sendable (String?) -> Void = { host in
        let first = resumed.withLock { done in
          if done { return false }
          done = true
          return true
        }
        guard first else { return }
        connection.cancel()
        continuation.resume(returning: host)
      }
      connection.onState { state in
        switch state {
        case .ready:
          finish(connection.remoteHost)
        case .failed, .cancelled:
          finish(nil)
        default:
          break
        }
      }
      connection.start()
      Task {
        try? await Task.sleep(for: timeout)
        finish(nil)
      }
    }
  }

  /// The endpoints of every player found: from the TXT record's `location` when it has one,
  /// by resolving the service otherwise, all the services at once.
  public static func discoverEndpoints(timeout: Duration = .seconds(3)) async -> [PlayerEndpoint] {
    let services = await browse(timeout: timeout)
    guard !Task.isCancelled else { return [] }
    return await withTaskGroup(of: (Int, PlayerEndpoint?).self) { group in
      for (index, service) in services.enumerated() {
        group.addTask {
          if let url = service.locationURL, let endpoint = PlayerEndpoint(url: url) {
            return (index, endpoint)
          }
          return (index, await resolveHost(of: service).flatMap { PlayerEndpoint(host: $0) })
        }
      }
      var found: [(Int, PlayerEndpoint)] = []
      for await (index, endpoint) in group {
        if let endpoint {
          found.append((index, endpoint))
        }
      }
      return found.sorted { $0.0 < $1.0 }.map(\.1)
    }
  }
}

/// `NWConnection` is thread-safe but not `Sendable`; this keeps one usable from the handlers.
nonisolated private final class ConnectionBox: @unchecked Sendable {
  private let connection: NWConnection

  init(_ connection: NWConnection) {
    self.connection = connection
  }

  func onState(_ handler: @escaping @Sendable (NWConnection.State) -> Void) {
    connection.stateUpdateHandler = handler
  }

  func start() {
    connection.start(queue: .global(qos: .userInitiated))
  }

  func cancel() {
    connection.cancel()
  }

  var remoteHost: String? {
    guard case .hostPort(let host, _) = connection.currentPath?.remoteEndpoint else { return nil }
    switch host {
    case .ipv4(let address): return "\(address)"
    case .ipv6(let address): return "\(address)".split(separator: "%").first.map(String.init)
    case .name(let name, _): return name
    @unknown default: return nil
    }
  }
}

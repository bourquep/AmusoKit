import Foundation
import Network
import Synchronization

/// A `NOTIFY` a player sent: which subscription it is for, its sequence number and its body.
/// Opaque outside the package: hand it to the `SonosGroupSession` or `TopologyMonitor` that
/// `owns(_:)` it.
nonisolated public struct GenaNotification: Sendable, Hashable {
  var sid: String
  var sequence: Int?
  var body: String
}

/// The HTTP server that receives the players' `NOTIFY`s, on an ephemeral port. One per app; every
/// subscription names its callback URL.
nonisolated public final class EventListener: @unchecked Sendable {
  public let notifications: AsyncStream<GenaNotification>

  private let continuation: AsyncStream<GenaNotification>.Continuation
  private let listener: NWListener
  private let queue = DispatchQueue(label: "\(Diagnostics.subsystem).events")
  private let state = Mutex<State>(State())

  private struct State {
    var port: UInt16?
    var hasFailed = false
    var readyContinuations: [CheckedContinuation<UInt16, any Error>] = []
    var connections: [ObjectIdentifier: ConnectionReader] = [:]
  }

  public init() throws {
    let parameters = NWParameters.tcp
    parameters.allowLocalEndpointReuse = true
    listener = try NWListener(using: parameters)
    (notifications, continuation) = AsyncStream.makeStream(of: GenaNotification.self, bufferingPolicy: .unbounded)
  }

  /// The port the listener got, once it is listening.
  public var port: UInt16? {
    state.withLock { $0.port }
  }

  /// Whether the listener stopped listening: iOS takes a suspended app's listening socket back.
  public var hasFailed: Bool {
    state.withLock { $0.hasFailed }
  }

  public func callbackURL(host: String) -> URL? {
    guard let port else { return nil }
    var components = URLComponents()
    components.scheme = "http"
    components.host = host
    components.port = Int(port)
    components.path = "/notify"
    return components.url
  }

  /// Starts listening and returns the port.
  public func start() async throws -> UInt16 {
    if let port { return port }
    return try await withCheckedThrowingContinuation { continuation in
      let started = state.withLock { state -> Bool in
        state.readyContinuations.append(continuation)
        return state.readyContinuations.count == 1
      }
      guard started else { return }
      listener.stateUpdateHandler = { [weak self] newState in
        guard let self else { return }
        switch newState {
        case .ready:
          let port = self.listener.port?.rawValue ?? 0
          let waiting = self.state.withLock { state in
            state.port = port
            defer { state.readyContinuations.removeAll() }
            return state.readyContinuations
          }
          waiting.forEach { $0.resume(returning: port) }
        case .failed(let error):
          let waiting = self.state.withLock { state in
            state.hasFailed = true
            defer { state.readyContinuations.removeAll() }
            return state.readyContinuations
          }
          waiting.forEach { $0.resume(throwing: error) }
        case .cancelled:
          self.state.withLock { $0.hasFailed = true }
        default:
          break
        }
      }
      listener.newConnectionHandler = { [weak self] connection in
        self?.accept(connection)
      }
      listener.start(queue: queue)
    }
  }

  public func stop() {
    listener.cancel()
    continuation.finish()
  }

  private func accept(_ connection: NWConnection) {
    let reader = ConnectionReader(connection: connection, queue: queue) { [weak self] request in
      self?.handle(request)
    } onClose: { [weak self] reader in
      _ = self?.state.withLock { $0.connections.removeValue(forKey: ObjectIdentifier(reader)) }
    }
    state.withLock { $0.connections[ObjectIdentifier(reader)] = reader }
    reader.start()
  }

  private func handle(_ request: HTTPRequest) {
    guard request.method == "NOTIFY", let sid = request[header: "sid"] else { return }
    continuation.yield(GenaNotification(
      sid: sid,
      sequence: request[header: "seq"].flatMap(Int.init),
      body: String(decoding: request.body, as: UTF8.self)
    ))
  }
}

/// Reads one request from a connection, answers 200 and closes. Its callbacks all run on the
/// listener's queue, one at a time.
nonisolated private final class ConnectionReader: @unchecked Sendable {
  private let connection: NWConnection
  private let queue: DispatchQueue
  private let onRequest: @Sendable (HTTPRequest) -> Void
  private let onClose: @Sendable (ConnectionReader) -> Void
  private var buffer = Data()

  init(
    connection: NWConnection,
    queue: DispatchQueue,
    onRequest: @escaping @Sendable (HTTPRequest) -> Void,
    onClose: @escaping @Sendable (ConnectionReader) -> Void
  ) {
    self.connection = connection
    self.queue = queue
    self.onRequest = onRequest
    self.onClose = onClose
  }

  func start() {
    connection.stateUpdateHandler = { [weak self] state in
      guard let self else { return }
      switch state {
      case .failed, .cancelled:
        self.onClose(self)
      default:
        break
      }
    }
    connection.start(queue: queue)
    receive()
  }

  private func receive() {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
      guard let self else { return }
      if let data {
        buffer.append(data)
      }
      do {
        if let (request, _) = try HTTPRequest.parse(buffer) {
          onRequest(request)
          respond(status: "200 OK")
          return
        }
      } catch {
        respond(status: "400 Bad Request")
        return
      }
      if isComplete || error != nil {
        connection.cancel()
      } else {
        receive()
      }
    }
  }

  private func respond(status: String) {
    let response = "HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    connection.send(content: Data(response.utf8), completion: .contentProcessed { [connection] _ in
      connection.cancel()
    })
  }
}

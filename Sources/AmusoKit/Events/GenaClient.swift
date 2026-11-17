import Foundation

/// A subscription to a player's service events.
nonisolated struct GenaSubscription: Sendable, Hashable {
  var service: UPnPService
  var endpoint: PlayerEndpoint
  var sid: String
  /// What the player granted, in seconds; `nil` for a subscription that never expires.
  var timeout: Int?
  var subscribedAt: Date

  init(service: UPnPService, endpoint: PlayerEndpoint, sid: String, timeout: Int?, subscribedAt: Date) {
    self.service = service
    self.endpoint = endpoint
    self.sid = sid
    self.timeout = timeout
    self.subscribedAt = subscribedAt
  }

  /// When to renew: well before the player forgets us.
  var renewalDelay: Duration {
    .seconds(Double(timeout ?? 3600) * 0.85)
  }

  /// `Second-3600` → 3600; `infinite` → `nil`.
  static func timeoutSeconds(from header: String?) -> Int? {
    guard let header else { return nil }
    let trimmed = header.trimmingCharacters(in: .whitespaces)
    if trimmed.lowercased().hasPrefix("second-") {
      return Int(trimmed.dropFirst("second-".count))
    }
    return nil
  }
}

/// Subscribes to, renews and cancels event subscriptions with the players (UPnP GENA).
nonisolated public struct GenaClient: Sendable {
  public typealias Logger = @Sendable (String) -> Void

  public var session: URLSession
  public var logger: Logger?

  public init(session: URLSession = SoapClient.makeSession(), logger: Logger? = nil) {
    self.session = session
    self.logger = logger
  }

  func subscribe(
    to service: UPnPService,
    on endpoint: PlayerEndpoint,
    callback: URL,
    timeout: Int = 300
  ) async throws -> GenaSubscription {
    var request = URLRequest(url: endpoint.url(path: service.eventPath))
    request.httpMethod = "SUBSCRIBE"
    request.setValue("<\(callback.absoluteString)>", forHTTPHeaderField: "CALLBACK")
    request.setValue("upnp:event", forHTTPHeaderField: "NT")
    request.setValue("Second-\(timeout)", forHTTPHeaderField: "TIMEOUT")
    let response = try await send(request, service: service, endpoint: endpoint)
    guard let sid = response.value(forHTTPHeaderField: "SID"), !sid.isEmpty else {
      throw SonosError.invalidResponse("SUBSCRIBE \(service.rawValue): no SID")
    }
    return GenaSubscription(
      service: service,
      endpoint: endpoint,
      sid: sid,
      timeout: GenaSubscription.timeoutSeconds(from: response.value(forHTTPHeaderField: "TIMEOUT")),
      subscribedAt: .now
    )
  }

  func renew(_ subscription: GenaSubscription, timeout: Int = 300) async throws -> GenaSubscription {
    var request = URLRequest(url: subscription.endpoint.url(path: subscription.service.eventPath))
    request.httpMethod = "SUBSCRIBE"
    request.setValue(subscription.sid, forHTTPHeaderField: "SID")
    request.setValue("Second-\(timeout)", forHTTPHeaderField: "TIMEOUT")
    let response = try await send(request, service: subscription.service, endpoint: subscription.endpoint)
    var renewed = subscription
    renewed.timeout = GenaSubscription.timeoutSeconds(from: response.value(forHTTPHeaderField: "TIMEOUT"))
    renewed.subscribedAt = .now
    return renewed
  }

  func unsubscribe(_ subscription: GenaSubscription) async throws {
    var request = URLRequest(url: subscription.endpoint.url(path: subscription.service.eventPath))
    request.httpMethod = "UNSUBSCRIBE"
    request.setValue(subscription.sid, forHTTPHeaderField: "SID")
    _ = try await send(request, service: subscription.service, endpoint: subscription.endpoint)
  }

  private func send(
    _ request: URLRequest, service: UPnPService, endpoint: PlayerEndpoint
  ) async throws -> HTTPURLResponse {
    let (_, response): (Data, URLResponse)
    do {
      (_, response) = try await session.data(for: request)
    } catch {
      throw SonosError.unreachable(endpoint, reason: error.localizedDescription)
    }
    guard let http = response as? HTTPURLResponse else {
      throw SonosError.invalidResponse("\(request.httpMethod ?? "") \(service.rawValue): not HTTP")
    }
    logger?("\(request.httpMethod ?? "") \(service.rawValue) on \(endpoint.host) → \(http.statusCode)")
    if http.statusCode == 403 {
      throw SonosError.upnpDisabled(endpoint)
    }
    guard http.statusCode < 400 else {
      let action = "\(request.httpMethod ?? "") \(service.rawValue)"
      throw SonosError.fault(SoapFault(httpStatus: http.statusCode), action: action)
    }
    return http
  }
}

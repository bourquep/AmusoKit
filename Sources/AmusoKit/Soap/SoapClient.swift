import Foundation

/// One SOAP request and what came back, for logs and fixtures.
nonisolated struct SoapExchange: Sendable {
  var action: String
  var url: URL
  var requestBody: String
  var statusCode: Int?
  var responseBody: String
  var duration: Duration
  var error: String?
}

/// Sends SOAP actions to players over HTTP.
nonisolated public struct SoapClient: Sendable {
  typealias Logger = @Sendable (SoapExchange) -> Void

  /// Seconds a call waits for its answer.
  public static let standardTimeout: TimeInterval = 8
  /// Seconds a queue change waits: a player adding to the queue right after `Play`, or to a long
  /// queue, can take well over the standard timeout to answer.
  public static let longTimeout: TimeInterval = 30

  public var session: URLSession
  /// For the actions whose `timeout` is `.long`, so that they wait without slowing the rest.
  public var longSession: URLSession
  var logger: Logger?

  public init(
    session: URLSession = SoapClient.makeSession(),
    longSession: URLSession = SoapClient.makeSession(timeout: SoapClient.longTimeout)
  ) {
    self.init(session: session, longSession: longSession, logger: nil)
  }

  /// With `logger`, which is handed every exchange.
  init(
    session: URLSession = SoapClient.makeSession(),
    longSession: URLSession = SoapClient.makeSession(timeout: SoapClient.longTimeout),
    logger: Logger?
  ) {
    self.session = session
    self.longSession = longSession
    self.logger = logger
  }

  /// A session with the short timeouts a local network deserves.
  public static func makeSession(timeout: TimeInterval = SoapClient.standardTimeout) -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = timeout
    configuration.timeoutIntervalForResource = timeout * 4
    configuration.waitsForConnectivity = false
    return URLSession(configuration: configuration)
  }

  func call(_ action: SoapAction, on endpoint: PlayerEndpoint) async throws -> SoapResponse {
    let url = endpoint.url(path: action.service.controlPath)
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
    request.setValue(action.soapActionHeader, forHTTPHeaderField: "SOAPACTION")
    let body = action.envelope()
    request.httpBody = Data(body.utf8)

    let clock = ContinuousClock()
    let start = clock.now
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await (action.timeout == .long ? longSession : session).data(for: request)
    } catch {
      let reason = (error as? URLError).map { "\($0.code.rawValue) \($0.localizedDescription)" }
        ?? error.localizedDescription
      logger?(SoapExchange(
        action: action.name, url: url, requestBody: body, statusCode: nil,
        responseBody: "", duration: clock.now - start, error: reason
      ))
      throw SonosError.unreachable(endpoint, reason: reason)
    }
    let status = (response as? HTTPURLResponse)?.statusCode
    let text = String(decoding: data, as: UTF8.self)
    logger?(SoapExchange(
      action: action.name, url: url, requestBody: body, statusCode: status,
      responseBody: text, duration: clock.now - start, error: nil
    ))
    guard let status else {
      throw SonosError.invalidResponse("\(action.name): not an HTTP response")
    }
    if status == 403 {
      throw SonosError.upnpDisabled(endpoint)
    }
    return try SoapResponse.parse(data, status: status, action: action)
  }
}

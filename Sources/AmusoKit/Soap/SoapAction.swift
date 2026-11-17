import Foundation

/// One SOAP call: the service, the action and its arguments in order.
nonisolated struct SoapAction: Sendable {
  /// How long the call may wait for its answer.
  enum Timeout: Sendable, Hashable {
    /// `SoapClient.standardTimeout`, what a local network deserves.
    case standard
    /// `SoapClient.longTimeout`, for the queue changes a busy player can take a while to answer.
    case long
  }

  var service: UPnPService
  var name: String
  var arguments: [(name: String, value: String)]
  var timeout: Timeout

  init(
    service: UPnPService,
    name: String,
    arguments: [(name: String, value: String)] = [],
    timeout: Timeout = .standard
  ) {
    self.service = service
    self.name = name
    self.arguments = arguments
    self.timeout = timeout
  }

  var soapActionHeader: String {
    "\"\(service.serviceType)#\(name)\""
  }

  func envelope() -> String {
    var body = ""
    for argument in arguments {
      body += "<\(argument.name)>\(XMLEscape.escape(argument.value))</\(argument.name)>"
    }
    return "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
      + "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\""
      + " s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\">"
      + "<s:Body><u:\(name) xmlns:u=\"\(service.serviceType)\">\(body)</u:\(name)></s:Body>"
      + "</s:Envelope>"
  }
}

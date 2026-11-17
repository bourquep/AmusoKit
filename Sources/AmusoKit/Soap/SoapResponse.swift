import Foundation

/// The values a SOAP action returned: the children of its `…Response` element.
nonisolated struct SoapResponse: Sendable, Hashable {
  var values: [String: String]

  subscript(key: String) -> String? {
    values[key]
  }

  func require(_ key: String) throws -> String {
    guard let value = values[key] else {
      throw SonosError.invalidResponse("missing \(key) in \(values.keys.sorted().joined(separator: ", "))")
    }
    return value
  }

  func int(_ key: String) -> Int? {
    values[key].flatMap(Int.init)
  }

  /// Parses an envelope, throwing the UPnP fault it carries when it is one.
  static func parse(_ data: Data, status: Int, action: SoapAction) throws -> SoapResponse {
    let root: XMLNode
    do {
      root = try XMLTree.parse(data)
    } catch {
      if status >= 400 {
        throw SonosError.fault(SoapFault(httpStatus: status), action: action.name)
      }
      throw SonosError.invalidResponse("\(action.name): \(error)")
    }
    if let fault = root.first("Fault") {
      let code = fault.first("errorCode").flatMap { Int($0.text) }
      // Sonos sends "UPnPError" as the fault string and, usually, no description at all.
      let detail = fault.first("errorDescription").map(\.text).flatMap { $0.isEmpty ? nil : $0 }
      throw SonosError.fault(
        SoapFault(httpStatus: status, upnpErrorCode: code, upnpErrorDescription: detail),
        action: action.name
      )
    }
    guard status < 400 else {
      throw SonosError.fault(SoapFault(httpStatus: status), action: action.name)
    }
    guard let body = root.first("Body"), let response = body.children.first else {
      throw SonosError.invalidResponse("\(action.name): no SOAP body")
    }
    var values: [String: String] = [:]
    for child in response.children {
      values[child.name] = child.text
    }
    return SoapResponse(values: values)
  }
}

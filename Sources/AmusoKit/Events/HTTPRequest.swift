import Foundation

/// The little HTTP the event listener needs: a request line, headers and a body sized by
/// `Content-Length`, which is how players send their `NOTIFY`s.
nonisolated struct HTTPRequest: Sendable, Hashable {
  var method: String
  var path: String
  /// Header names lowercased.
  var headers: [String: String]
  var body: Data

  subscript(header name: String) -> String? {
    headers[name.lowercased()]
  }

  /// A complete request at the start of `data`, with how many bytes it took, or `nil` while more
  /// bytes are needed.
  static func parse(_ data: Data) throws -> (request: HTTPRequest, consumed: Int)? {
    guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else {
      if data.count > 64 * 1024 {
        throw HTTPRequestError.headersTooLong
      }
      return nil
    }
    let head = String(decoding: data[data.startIndex..<headerEnd.lowerBound], as: UTF8.self)
    var lines = head.components(separatedBy: "\r\n")
    guard let requestLine = lines.first else { throw HTTPRequestError.malformed }
    lines.removeFirst()
    let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
    guard parts.count >= 2 else { throw HTTPRequestError.malformed }
    var headers: [String: String] = [:]
    for line in lines where !line.isEmpty {
      guard let colon = line.firstIndex(of: ":") else { throw HTTPRequestError.malformed }
      let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
      let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      headers[name] = value
    }
    let length = headers["content-length"].flatMap(Int.init) ?? 0
    let bodyStart = headerEnd.upperBound
    guard data.count - (bodyStart - data.startIndex) >= length else { return nil }
    let body = data[bodyStart..<(bodyStart + length)]
    let request = HTTPRequest(method: String(parts[0]), path: String(parts[1]), headers: headers, body: Data(body))
    return (request, bodyStart - data.startIndex + length)
  }
}

nonisolated enum HTTPRequestError: Error, Sendable {
  case malformed
  case headersTooLong
}

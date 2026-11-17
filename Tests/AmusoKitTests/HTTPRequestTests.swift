import Foundation
import Testing
@testable import AmusoKit

struct HTTPRequestTests {
  private func notify(body: String, extraHeaders: String = "") -> Data {
    Data("""
    NOTIFY /notify HTTP/1.1\r
    HOST: 192.168.1.130:55759\r
    CONTENT-TYPE: text/xml; charset="utf-8"\r
    CONTENT-LENGTH: \(body.utf8.count)\r
    NT: upnp:event\r
    NTS: upnp:propchange\r
    SID: uuid:RINCON_000E58A0000101400_sub0000000781\r
    SEQ: 3\r
    \(extraHeaders)\r
    \(body)
    """.utf8)
  }

  @Test func parsesACompleteNotify() throws {
    let body = try Fixtures.string("Notify-GroupRenderingControl-1.xml")
    let (request, consumed) = try #require(try HTTPRequest.parse(notify(body: body)))
    #expect(request.method == "NOTIFY")
    #expect(request.path == "/notify")
    #expect(request[header: "SID"] == "uuid:RINCON_000E58A0000101400_sub0000000781")
    #expect(request[header: "seq"] == "3")
    #expect(String(decoding: request.body, as: UTF8.self) == body)
    #expect(consumed == notify(body: body).count)
  }

  @Test func waitsForTheWholeBody() throws {
    let data = notify(body: "<e:propertyset/>")
    #expect(try HTTPRequest.parse(data.prefix(data.count - 5)) == nil)
    #expect(try HTTPRequest.parse(Data("NOTIFY /notify HTTP/1.1\r\nSID: x".utf8)) == nil)
  }

  @Test func rejectsWhatIsNotARequest() {
    #expect(throws: HTTPRequestError.self) {
      try HTTPRequest.parse(Data("garbage\r\n\r\n".utf8))
    }
  }
}

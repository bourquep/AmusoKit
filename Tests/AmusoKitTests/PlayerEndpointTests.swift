import Foundation
import Testing
@testable import AmusoKit

struct PlayerEndpointTests {
  @Test func buildsControlURLs() throws {
    let endpoint = try #require(PlayerEndpoint(host: "192.168.1.10"))
    #expect(endpoint.port == 1400)
    let control = endpoint.url(path: "/MediaRenderer/AVTransport/Control").absoluteString
    #expect(control == "http://192.168.1.10:1400/MediaRenderer/AVTransport/Control")
    let description = endpoint.url(path: DeviceDescription.path).absoluteString
    #expect(description == "http://192.168.1.10:1400/xml/device_description.xml")
  }

  @Test func readsThePlayerOutOfALocationURL() throws {
    let location = try #require(URL(string: "http://192.168.1.126:1400/xml/device_description.xml"))
    #expect(PlayerEndpoint(url: location)?.host == "192.168.1.126")
    let bare = try #require(URL(string: "mailto:nobody"))
    #expect(PlayerEndpoint(url: bare) == nil)
  }
}

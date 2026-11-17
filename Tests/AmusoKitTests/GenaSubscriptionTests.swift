import Foundation
import Testing
@testable import AmusoKit

struct GenaSubscriptionTests {
  @Test func readsTheGrantedTimeout() {
    #expect(GenaSubscription.timeoutSeconds(from: "Second-300") == 300)
    #expect(GenaSubscription.timeoutSeconds(from: "second-3600") == 3600)
    #expect(GenaSubscription.timeoutSeconds(from: "infinite") == nil)
    #expect(GenaSubscription.timeoutSeconds(from: nil) == nil)
  }

  @Test func renewsWellBeforeTheTimeout() throws {
    let endpoint = try #require(PlayerEndpoint(host: "192.168.1.10"))
    let subscription = GenaSubscription(
      service: .avTransport, endpoint: endpoint, sid: "uuid:x", timeout: 300, subscribedAt: .now)
    #expect(subscription.renewalDelay == .seconds(255))
    let forever = GenaSubscription(
      service: .avTransport, endpoint: endpoint, sid: "uuid:x", timeout: nil, subscribedAt: .now)
    #expect(forever.renewalDelay == .seconds(3060))
  }
}

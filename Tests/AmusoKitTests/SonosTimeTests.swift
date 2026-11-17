import Foundation
import Testing
@testable import AmusoKit

struct SonosTimeTests {
  @Test func readsAndWritesPlayerTimes() {
    #expect(SonosTime.duration(from: "0:04:16") == .seconds(256))
    #expect(SonosTime.duration(from: "1:02:03.500") == .seconds(3723) + .milliseconds(500))
    #expect(SonosTime.duration(from: "NOT_IMPLEMENTED") == nil)
    #expect(SonosTime.duration(from: "") == nil)
    #expect(SonosTime.text(from: .seconds(256)) == "0:04:16")
    #expect(SonosTime.text(from: .seconds(3723)) == "1:02:03")
  }

  @Test func transportStatesMapFromThePlayerValues() {
    #expect(TransportState(sonosValue: "PLAYING") == .playing)
    #expect(TransportState(sonosValue: "PAUSED_PLAYBACK") == .paused)
    #expect(TransportState(sonosValue: "SOMETHING_NEW") == .unknown)
  }
}

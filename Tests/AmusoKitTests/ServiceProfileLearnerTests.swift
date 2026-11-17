import Foundation
import Testing
@testable import AmusoKit

struct ServiceProfileLearnerTests {
  @Test func learnsTheSerialAndFlagsFromPlayerURIs() {
    let profile = ServiceProfileLearner.learn(from: [
      "x-sonos-http:librarytrack%3ai.td7usv0NsE6mv.mp4?sid=204&flags=8232&sn=3",
      "x-sonosapi-hls-static:song%3a1592575938?sid=204&flags=8232&sn=3",
      "x-rincon-cpcontainer:1004206calbum%3a1592575933?sid=204&flags=8300&sn=3",
      "x-sonosapi-radio:tunein%3a1234?sid=254&flags=8300&sn=1"
    ])
    #expect(profile.serialNumber == 3)
    #expect(profile.libraryTrackFlags == 8232)
    #expect(profile.songFlags == 8232)
    #expect(profile.containerFlags == 8300)
    #expect(profile.sampleURIs.count == 3)
    let expected = AppleMusicURIStyle.sonosApp(
      serial: 3, songFlags: 8232, libraryTrackFlags: 8232, containerFlags: 8300)
    #expect(profile.preferredStyle == expected)
  }

  @Test func nothingLearnedMeansServiceOnly() {
    let profile = ServiceProfileLearner.learn(from: ["x-rincon-stream:RINCON_1"])
    #expect(profile.isEmpty)
    #expect(profile.preferredStyle == .serviceOnly)
  }
}

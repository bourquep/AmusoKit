import Foundation
import Testing
@testable import AmusoKit

struct StreamInfoTests {
  @Test func readsWhatTheEra300ReportsForDolbyAtmos() throws {
    let info = try #require(StreamInfo("bd:16,sr:48000,c:11,l:0,d:1"))
    #expect(info.bitDepth == 16)
    #expect(info.sampleRate == 48_000)
    #expect(info.codec == 11)
    #expect(!info.isLossless)
    #expect(info.isDolbyAtmos)
  }

  @Test func readsWhatTheEra300ReportsForLossless() throws {
    let info = try #require(StreamInfo("bd:24,sr:48000,c:6,l:1,d:0"))
    #expect(info == StreamInfo(bitDepth: 24, sampleRate: 48_000, codec: 6, isLossless: true))
  }

  @Test func aStoppedPlayerReportsZeros() {
    #expect(StreamInfo("bd:0,sr:0,c:0,l:0,d:0") == StreamInfo())
  }

  @Test func unknownKeysAreSkippedAndEmptyTextIsNothing() {
    #expect(StreamInfo("bd:24, sr:96000, x:7, l:1") == StreamInfo(bitDepth: 24, sampleRate: 96_000, isLossless: true))
    #expect(StreamInfo("") == nil)
    #expect(StreamInfo("nonsense") == nil)
  }

  @Test func onlyEventsCarryIt() throws {
    let response = try SoapResponse.parse(
      try Fixtures.data("GetPositionInfo-catalog-song.xml"),
      status: 200,
      action: SoapAction(service: .avTransport, name: "GetPositionInfo")
    )
    let item = try #require(try DIDLLite.parse(try response.require("TrackMetaData")).first)
    #expect(item.streamInfo == nil)
  }
}

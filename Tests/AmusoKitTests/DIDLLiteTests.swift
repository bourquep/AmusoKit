import Foundation
import Testing
@testable import AmusoKit

struct DIDLLiteTests {
  @Test func parsesTheQueueThePlayerReturns() throws {
    let response = try SoapResponse.parse(
      try Fixtures.data("Browse-queue.xml"),
      status: 200,
      action: SoapAction(service: .contentDirectory, name: "Browse")
    )
    let items = try DIDLLite.parse(try response.require("Result"))
    #expect(items.count == 9)
    #expect(response.int("TotalMatches") == 9)
    let first = try #require(items.first)
    #expect(first.title == "New World Order")
    #expect(first.creator == "The Pineapple Thief")
    #expect(first.album == "Far and Wide")
    #expect(first.id == "Q:0/1")
    #expect(first.primaryURI == "x-sonos-http:librarytrack%3ai.HpYd4V3rHfFIO.mp4?sid=204&flags=8232&sn=3")
    #expect(first.resources.first?.protocolInfo == "sonos.com-http:*:audio/mp4:*")
    #expect(first.upnpClass == "object.item.audioItem.musicTrack")
    #expect(first.libraryTrackID == "i.HpYd4V3rHfFIO")
    #expect(first.catalogSongID == nil)
  }

  @Test func parsesTheCurrentTrackOfACatalogSong() throws {
    let response = try SoapResponse.parse(
      try Fixtures.data("GetPositionInfo-catalog-song.xml"),
      status: 200,
      action: SoapAction(service: .avTransport, name: "GetPositionInfo")
    )
    let item = try #require(try DIDLLite.parse(try response.require("TrackMetaData")).first)
    #expect(item.title == "Harridan")
    #expect(item.creator == "Porcupine Tree")
    #expect(item.primaryURI?.hasPrefix("x-sonosapi-hls-static:song%3a1592575938") == true)
    #expect(item.resources.first?.protocolInfo == "sonos.com-http:*:application/x-mpegURL:*")
    #expect(item.resources.first?.durationText == "0:08:07")
    #expect(item.catalogSongID == "1592575938")
    #expect(response["RelTime"] == "0:00:00")
    #expect(SonosTime.duration(from: response["TrackDuration"] ?? "") == .seconds(8 * 60 + 7))
  }

  @Test func emptyAndNotImplementedMetadataParseToNothing() throws {
    #expect(try DIDLLite.parse("").isEmpty)
    #expect(try DIDLLite.parse("NOT_IMPLEMENTED").isEmpty)
  }

  @Test func serializesWhatAPlayerNeedsToEnqueue() throws {
    let xml = DIDLLite.serialize(DIDLLite.ItemSpec(
      id: "10032020song%3a1",
      isContainer: false,
      title: "A & B",
      upnpClass: "object.item.audioItem.musicTrack",
      descriptionToken: AppleMusicURI.descriptionToken
    ))
    #expect(xml.contains("<item id=\"10032020song%3a1\" parentID=\"-1\" restricted=\"true\">"))
    #expect(xml.contains("<dc:title>A &amp; B</dc:title>"))
    let desc = "<desc id=\"cdudn\" nameSpace=\"urn:schemas-rinconnetworks-com:metadata-1-0/\">"
      + "SA_RINCON52231_X_#Svc52231-0-Token</desc>"
    #expect(xml.contains(desc))
    let parsed = try #require(try DIDLLite.parse(xml).first)
    #expect(parsed.title == "A & B")
    #expect(parsed.descriptionToken == AppleMusicURI.descriptionToken)
  }
}

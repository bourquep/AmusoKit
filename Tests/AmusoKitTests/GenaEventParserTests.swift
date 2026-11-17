import Foundation
import Testing
@testable import AmusoKit

/// The players' `NOTIFY`s, captured from the Era 300 pair on Oct 27, 2026.
struct GenaEventParserTests {
  @Test func readsAVTransportsLastChange() throws {
    let event = try GenaEventParser.parse(try Fixtures.string("Notify-AVTransport-1.xml"))
    #expect(event["TransportState"] == "PAUSED_PLAYBACK")
    #expect(event["CurrentTrack"] == "8")
    #expect(event["NumberOfTracks"] == "9")
    #expect(event["CurrentPlayMode"] == "NORMAL")
    #expect(event["AVTransportURI"] == "x-rincon-queue:RINCON_000E58A0000101400#0")
    #expect(event["CurrentTrackURI"]?.hasPrefix("x-sonosapi-hls-static:librarytrack%3ai.td7usv0NsE6mv") == true)
    let metadata = try DIDLLite.parse(try #require(event["CurrentTrackMetaData"]))
    #expect(metadata.first?.title == "Who Wants It?")
    #expect(metadata.first?.creator == "The Pineapple Thief")
    #expect(metadata.first?.resources.first?.durationText == "0:04:16")
  }

  @Test func readsRenderingControlsChannels() throws {
    let event = try GenaEventParser.parse(try Fixtures.string("Notify-RenderingControl-2.xml"))
    #expect(event["Volume/Master"] == "3")
    #expect(event["Volume"] == "3")
    #expect(event["Volume/LF"] == "100")
    let initial = try GenaEventParser.parse(try Fixtures.string("Notify-RenderingControl-1.xml"))
    #expect(initial["Mute/Master"] == "0")
    #expect(initial["Volume"] == "2")
  }

  @Test func readsPlainPropertiesOfTheOtherServices() throws {
    let group = try GenaEventParser.parse(try Fixtures.string("Notify-GroupRenderingControl-2.xml"))
    #expect(group.properties["GroupVolume"] == "3")
    #expect(group.properties["GroupMute"] == "0")
    #expect(group.lastChange.isEmpty)
    let directory = try GenaEventParser.parse(try Fixtures.string("Notify-ContentDirectory-1.xml"))
    #expect(directory.properties["ContainerUpdateIDs"] == "Q:0,26")
    let topology = try GenaEventParser.parse(try Fixtures.string("Notify-ZoneGroupTopology-1.xml"))
    let state = try #require(topology.properties["ZoneGroupState"])
    let household = try ZoneGroupTopologyService.parse(zoneGroupState: state)
    #expect(household.groups.map(\.name) == ["Véranda", "Living Room"])
  }
}

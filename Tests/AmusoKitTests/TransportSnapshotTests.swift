import Foundation
import Testing
@testable import AmusoKit

struct TransportSnapshotTests {
  private func lastChange(_ fixture: String) throws -> [String: String] {
    try GenaEventParser.parse(try Fixtures.string(fixture)).lastChange
  }

  @Test func aFullEventFillsTheSnapshot() throws {
    let snapshot = TransportSnapshot().applying(lastChange: try lastChange("Notify-AVTransport-1.xml"))
    #expect(snapshot.state == .paused)
    #expect(snapshot.source == .queue)
    #expect(snapshot.playMode == .normal)
    #expect(snapshot.numberOfTracks == 9)
    #expect(snapshot.currentTrackNumber == 8)
    let track = try #require(snapshot.track)
    #expect(track.title == "Who Wants It?")
    #expect(track.artist == "The Pineapple Thief")
    #expect(track.album == "Far and Wide")
    #expect(track.queueIndex == 8)
    #expect(track.duration == .seconds(256))
    #expect(track.libraryTrackID == "i.td7usv0NsE6mv")
    #expect(track.catalogSongID == nil)
    #expect(track.albumArtPath?.hasPrefix("/getaa?") == true)
    #expect(track.streamInfo == StreamInfo(bitDepth: 16, sampleRate: 48_000, codec: 11, isDolbyAtmos: true))
  }

  @Test func aCurrentTrackEventReplacesTheStreamInfo() throws {
    let first = TransportSnapshot().applying(lastChange: try lastChange("Notify-AVTransport-1.xml"))
    let metadata = "<DIDL-Lite \(DIDLLite.namespaces)><item id=\"-1\" parentID=\"-1\" restricted=\"true\">"
      + "<res>\(XMLEscape.escape(first.track?.uri ?? ""))</res><r:streamInfo>bd:0,sr:0,c:0,l:0,d:0</r:streamInfo>"
      + "<dc:title>Who Wants It?</dc:title></item></DIDL-Lite>"
    let stopped = first.applying(lastChange: ["CurrentTrackMetaData": metadata])
    #expect(stopped.track?.streamInfo == StreamInfo())
    #expect(stopped.applying(lastChange: ["TransportState": "PLAYING"]).track?.streamInfo == StreamInfo())
  }

  @Test func aPartialEventKeepsWhatItDoesNotMention() throws {
    let first = TransportSnapshot().applying(lastChange: try lastChange("Notify-AVTransport-1.xml"))
    let next = first.applying(lastChange: ["TransportState": "TRANSITIONING"])
    #expect(next.state == .transitioning)
    #expect(next.track == first.track)
    #expect(next.numberOfTracks == 9)
    #expect(next.isPlaying)
  }

  @Test func aNewTrackDropsThePositionAndAnEmptyURIDropsTheTrack() throws {
    var first = TransportSnapshot().applying(lastChange: try lastChange("Notify-AVTransport-1.xml"))
    first.position = PositionClock(relativeTime: .seconds(60))
    let changed = first.applying(
      lastChange: ["CurrentTrackURI": "x-sonos-http:song%3a1.mp4?sid=204", "CurrentTrack": "9"])
    #expect(changed.position == nil)
    #expect(changed.track?.uri == "x-sonos-http:song%3a1.mp4?sid=204")
    #expect(changed.track?.catalogSongID == "1")
    let empty = changed.applying(lastChange: ["CurrentTrackURI": "", "CurrentTrackMetaData": ""])
    #expect(empty.track == nil)
  }

  @Test func sourcesAreReadOffTheTransportURI() {
    #expect(PlaySource(transportURI: "x-rincon-queue:RINCON_1#0") == .queue)
    #expect(PlaySource(transportURI: "x-rincon-stream:RINCON_1") == .lineIn)
    #expect(PlaySource(transportURI: "x-sonos-htastream:RINCON_1:spdif") == .television)
    #expect(PlaySource(transportURI: "x-sonosapi-radio:ST%3a1?sid=236") == .radio)
    let station = PlaySource(transportURI: "x-sonosapi-radio:radio%3ara.475672?sid=204")
    #expect(station == .appleMusicStation(id: "ra.475672"))
    #expect(PlaySource(transportURI: "x-sonosapi-radio:radio%3ara.978194965?sid=236") == .radio)
    #expect(PlaySource(transportURI: "x-sonos-vli:RINCON_1:2,airplay:abc") == .stream)
    #expect(PlaySource(transportURI: "x-rincon:RINCON_2") == .follower(coordinatorUUID: "RINCON_2"))
    #expect(PlaySource(transportURI: "") == .nothing)
  }

  @Test func appleMusicIDsComeOutOfURIs() {
    let hls = "x-sonosapi-hls-static:song%3a1592575938?sid=204&flags=8232&sn=3"
    #expect(NowPlayingTrack.appleMusicObject(in: hls, kind: "song") == "1592575938")
    let mp4 = "x-sonos-http:song%3a1592575938.mp4?sid=204"
    #expect(NowPlayingTrack.appleMusicObject(in: mp4, kind: "song") == "1592575938")
    let library = "x-sonos-http:librarytrack%3ai.abc.mp4?sid=204&sn=3"
    #expect(NowPlayingTrack.appleMusicObject(in: library, kind: "librarytrack") == "i.abc")
    #expect(NowPlayingTrack.appleMusicObject(in: "x-sonosapi-radio:ST%3a1?sid=236", kind: "song") == nil)
    // A station's songs, as the player streams them.
    let station = "x-sonosprog-http:song%3a193251230.mp4?sid=204&flags=8232&sn=3"
    #expect(NowPlayingTrack.appleMusicObject(in: station, kind: "song") == "193251230")
  }

  @Test func thePositionClockCountsForwardOnlyWhilePlaying() {
    let clock = PositionClock(relativeTime: .seconds(60), observedAt: .now - .seconds(10))
    #expect(clock.position(playing: false) == .seconds(60))
    #expect(clock.position(playing: true) >= .seconds(70))
    #expect(clock.position(playing: true) < .seconds(71))
  }

  @Test func playModesCombineShuffleAndRepeat() {
    for mode in PlayMode.allCases {
      #expect(PlayMode.mode(shuffled: mode.isShuffled, repeating: mode.repeatMode) == mode)
    }
    #expect(PlayMode.shuffle.isShuffled)
    #expect(PlayMode.shuffle.repeatMode == .all)
    #expect(PlayMode.repeatOne.repeatMode == .one)
  }
}

struct AlbumArtURLTests {
  @Test func thePlayersArtKeepsItsQuery() throws {
    let endpoint = try #require(PlayerEndpoint(host: "192.168.1.10"))
    let track = NowPlayingTrack(
      uri: "x-sonos-http:librarytrack%3ai.td7usv0NsE6mv.mp4?sid=204",
      title: "Who Wants It?",
      albumArtPath: "/getaa?s=1&u=x-sonos-http%3alibrarytrack%253ai.td7usv0NsE6mv.mp4%3fsid%3d204"
    )
    let url = try #require(track.albumArtURL(on: endpoint))
    let expected = "http://192.168.1.10:1400/getaa?s=1&u="
      + "x-sonos-http%3alibrarytrack%253ai.td7usv0NsE6mv.mp4%3fsid%3d204"
    #expect(url.absoluteString == expected)
    let absolute = NowPlayingTrack(uri: "", title: "", albumArtPath: "https://example.invalid/a.jpg")
    #expect(absolute.albumArtURL(on: endpoint)?.absoluteString == "https://example.invalid/a.jpg")
    #expect(NowPlayingTrack(uri: "", title: "").albumArtURL(on: endpoint) == nil)
  }
}

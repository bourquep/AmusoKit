import Foundation
import Testing
@testable import AmusoKit

struct AppleMusicURITests {
  @Test func parsesShareLinksAndSonosObjects() {
    let albumLink = "https://music.apple.com/ca/album/closure-continuation/1592575933"
    #expect(AppleMusicItem.parse(albumLink) == .album("1592575933"))
    #expect(AppleMusicItem.parse(albumLink + "?i=1592575938") == .song("1592575938"))
    #expect(AppleMusicItem.parse("https://music.apple.com/ca/song/harridan/1592575938") == .song("1592575938"))
    #expect(AppleMusicItem.parse("https://music.apple.com/ca/playlist/x/pl.u-abc") == .playlist("pl.u-abc"))
    #expect(AppleMusicItem.parse("librarytrack:i.HpYd4V3rHfFIO") == .libraryTrack("i.HpYd4V3rHfFIO"))
    #expect(AppleMusicItem.parse("libraryalbum:l.abc") == .libraryAlbum("l.abc"))
    #expect(AppleMusicItem.parse("https://music.apple.com/ca/station/hooverphonic/ra.475672") == .station("ra.475672"))
    #expect(AppleMusicItem.parse("radio:ra.u-0a1b2c3d") == .station("ra.u-0a1b2c3d"))
    #expect(AppleMusicItem.parse("nonsense") == nil)
    #expect(AppleMusicItem.parse("song:") == nil)
  }

  @Test(arguments: [
    (AppleMusicURIStyle.serviceOnly, "x-sonos-http:song%3a1592575938.mp4?sid=204"),
    (.sonosApp(serial: 3), "x-sonos-http:song%3a1592575938.mp4?sid=204&flags=8224&sn=3"),
    (.bare, "song%3a1592575938"),
    (.serviceAndSerial(serial: 3), "x-sonos-http:song%3a1592575938.mp4?sid=204&sn=3")
  ])
  func songURIsPerStyle(style: AppleMusicURIStyle, expected: String) {
    let item = AppleMusicURI.enqueueItem(.song("1592575938"), style: style, title: "Harridan")
    #expect(item.uri == expected)
    #expect(item.itemID == "10032020song%3a1592575938")
    #expect(item.metadata.contains("object.item.audioItem.musicTrack"))
    #expect(item.metadata.contains(AppleMusicURI.descriptionToken))
  }

  @Test func libraryTracksUseTheirOwnFlagsInTheSonosAppStyle() {
    let item = AppleMusicURI.enqueueItem(.libraryTrack("i.HpYd4V3rHfFIO"), style: .sonosApp(serial: 3))
    #expect(item.uri == "x-sonos-http:librarytrack%3ai.HpYd4V3rHfFIO.mp4?sid=204&flags=8232&sn=3")
    #expect(item.itemID == "10032020librarytrack%3ai.HpYd4V3rHfFIO")
  }

  @Test func containersUseTheRinconScheme() {
    let album = AppleMusicURI.enqueueItem(.album("1592575933"), style: .serviceOnly)
    #expect(album.uri == "x-rincon-cpcontainer:1004206calbum%3a1592575933?sid=204")
    #expect(album.itemID == "1004206calbum%3a1592575933")
    #expect(album.metadata.contains("<container id=\"1004206calbum%3a1592575933\""))
    #expect(album.metadata.contains("object.container.album.musicAlbum"))

    let bareAlbum = AppleMusicURI.enqueueItem(.album("1"), style: .bare)
    #expect(bareAlbum.uri == "x-rincon-cpcontainer:1004206calbum%3a1")
    #expect(bareAlbum.itemID == "00040000album%3a1")

    let playlist = AppleMusicURI.enqueueItem(.playlist("pl.u-abc"), style: .sonosApp(serial: 3))
    #expect(playlist.uri == "x-rincon-cpcontainer:1006206cplaylist%3apl.u-abc?sid=204&flags=8300&sn=3")
    #expect(playlist.metadata.contains("object.container.playlistContainer"))
  }

  /// What the Era 300 pair played on Oct 28, 2026 (README, _Apple Music_).
  @Test(arguments: [AppleMusicURIStyle.serviceOnly, .sonosApp(serial: 3), .bare])
  func stationsAreTunedToWithTheRadioScheme(style: AppleMusicURIStyle) {
    let station = AppleMusicURI.enqueueItem(
      .station("ra.475672"), style: style, title: "Hooverphonic et autres artistes")
    #expect(station.uri == "x-sonosapi-radio:radio%3ara.475672?sid=204")
    #expect(station.itemID == "100c706cradio%3ara.475672")
    #expect(station.metadata.contains("<item id=\"100c706cradio%3ara.475672\" parentID=\"-1\""))
    #expect(station.metadata.contains("object.item.audioItem.audioBroadcast"))
    #expect(station.metadata.contains(AppleMusicURI.descriptionToken))
  }

  @Test func theQueueURINamesTheCoordinator() {
    let uri = AppleMusicURI.queueURI(coordinatorUUID: "RINCON_000E58A0000101400")
    #expect(uri == "x-rincon-queue:RINCON_000E58A0000101400#0")
  }
}

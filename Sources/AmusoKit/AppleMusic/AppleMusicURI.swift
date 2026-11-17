import Foundation

/// The URI styles seen in the wild for Apple Music on Sonos. The README's _Apple Music_
/// section says where each comes from and what was found on real players.
nonisolated public enum AppleMusicURIStyle: Hashable, Sendable {
  /// A: what the Sonos app writes, with the household's account serial and its flags.
  case sonosApp(serial: Int, songFlags: Int = 8224, libraryTrackFlags: Int = 8232, containerFlags: Int = 8300)
  /// B: `?sid=204` only.
  case serviceOnly
  /// C: SoCo's share links, no scheme on songs, no query at all.
  case bare
  /// D: `?sid=204&sn=<sn>`.
  case serviceAndSerial(serial: Int)

  public var letter: String {
    switch self {
    case .sonosApp: "A"
    case .serviceOnly: "B"
    case .bare: "C"
    case .serviceAndSerial: "D"
    }
  }
}

/// What `AddURIToQueue` takes, or `SetAVTransportURI` for a station: the URI and its DIDL-Lite
/// metadata.
nonisolated public struct EnqueueItem: Hashable, Sendable {
  public var uri: String
  public var metadata: String
  public var itemID: String
  /// The title sent in the metadata, to name the item when a player refuses it.
  public var title: String

  public init(uri: String, metadata: String, itemID: String, title: String = "") {
    self.uri = uri
    self.metadata = metadata
    self.itemID = itemID
    self.title = title
  }
}

nonisolated public enum AppleMusicURI {
  public static let serviceID = 204
  public static let serviceType = 52_231
  public static let descriptionToken = "SA_RINCON52231_X_#Svc52231-0-Token"

  /// The queue of a group, which `SetAVTransportURI` targets before `Play`.
  public static func queueURI(coordinatorUUID: String) -> String {
    "x-rincon-queue:\(coordinatorUUID)#0"
  }

  public static func enqueueItem(
    _ item: AppleMusicItem,
    style: AppleMusicURIStyle,
    title: String = "",
    parentID: String? = nil
  ) -> EnqueueItem {
    let object = item.encodedObject
    let uri: String
    let itemID: String
    switch item {
    case .song, .libraryTrack:
      let base = "x-sonos-http:\(object).mp4"
      itemID = "10032020\(object)"
      switch style {
      case .sonosApp(let serial, let songFlags, let libraryTrackFlags, _):
        let flags = item.isLibraryItem ? libraryTrackFlags : songFlags
        uri = "\(base)?sid=\(serviceID)&flags=\(flags)&sn=\(serial)"
      case .serviceOnly: uri = "\(base)?sid=\(serviceID)"
      case .bare: uri = object
      case .serviceAndSerial(let serial): uri = "\(base)?sid=\(serviceID)&sn=\(serial)"
      }
    case .album, .libraryAlbum:
      let base = "x-rincon-cpcontainer:1004206c\(object)"
      itemID = style == .bare ? "00040000\(object)" : "1004206c\(object)"
      uri = containerURI(base: base, style: style)
    case .playlist, .libraryPlaylist:
      let base = "x-rincon-cpcontainer:1006206c\(object)"
      itemID = "1006206c\(object)"
      uri = containerURI(base: base, style: style)
    case .station:
      // Only `?sid=204` was tried on a player (README, _Apple Music_), so every
      // style sends it.
      itemID = "100c706c\(object)"
      uri = "x-sonosapi-radio:\(object)?sid=\(serviceID)"
    }
    let metadata = DIDLLite.serialize(DIDLLite.ItemSpec(
      id: itemID,
      parentID: parentID ?? "-1",
      isContainer: item.isContainer,
      title: title,
      upnpClass: item.upnpClass,
      descriptionToken: descriptionToken
    ))
    return EnqueueItem(uri: uri, metadata: metadata, itemID: itemID, title: title)
  }

  private static func containerURI(base: String, style: AppleMusicURIStyle) -> String {
    switch style {
    case .sonosApp(let serial, _, _, let containerFlags):
      "\(base)?sid=\(serviceID)&flags=\(containerFlags)&sn=\(serial)"
    case .serviceOnly: "\(base)?sid=\(serviceID)"
    case .bare: base
    case .serviceAndSerial(let serial): "\(base)?sid=\(serviceID)&sn=\(serial)"
    }
  }
}

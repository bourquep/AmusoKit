import Foundation

/// An Apple Music object a player can be told to play: a catalog song, album or playlist, a
/// station, or an item of the user's library by its library identifier (`i.…`, `l.…`, `p.…`),
/// which is how the Sonos app itself enqueues the library.
nonisolated public enum AppleMusicItem: Hashable, Sendable, CustomStringConvertible {
  case song(String)
  case album(String)
  /// A catalog playlist (`pl.…`) or a user's playlist by its global id (`pl.u-…`).
  case playlist(String)
  case libraryTrack(String)
  case libraryAlbum(String)
  case libraryPlaylist(String)
  /// A station (`ra.…`): an artist's, the user's own (`ra.u-…`) or Découverte (`ra.q-…`). It is
  /// not enqueued but tuned to, and leaves the queue alone.
  case station(String)

  public var id: String {
    switch self {
    case .song(let id), .album(let id), .playlist(let id),
      .libraryTrack(let id), .libraryAlbum(let id), .libraryPlaylist(let id), .station(let id):
      id
    }
  }

  public var isContainer: Bool {
    switch self {
    case .song, .libraryTrack, .station: false
    case .album, .playlist, .libraryAlbum, .libraryPlaylist: true
    }
  }

  public var isLibraryItem: Bool {
    switch self {
    case .libraryTrack, .libraryAlbum, .libraryPlaylist: true
    case .song, .album, .playlist, .station: false
    }
  }

  /// The object as Sonos names it: `song:123`, `album:123`, `playlist:pl.…`, `librarytrack:i.…`,
  /// `radio:ra.…`.
  public var sonosObject: String {
    switch self {
    case .song(let id): "song:\(id)"
    case .album(let id): "album:\(id)"
    case .playlist(let id): "playlist:\(id)"
    case .libraryTrack(let id): "librarytrack:\(id)"
    case .libraryAlbum(let id): "libraryalbum:\(id)"
    case .libraryPlaylist(let id): "libraryplaylist:\(id)"
    case .station(let id): "radio:\(id)"
    }
  }

  /// `sonosObject` with its colon percent-encoded, as players write it.
  public var encodedObject: String {
    sonosObject.replacing(":", with: "%3a")
  }

  public var upnpClass: String {
    switch self {
    case .song, .libraryTrack: "object.item.audioItem.musicTrack"
    case .album, .libraryAlbum: "object.container.album.musicAlbum"
    case .playlist, .libraryPlaylist: "object.container.playlistContainer"
    case .station: "object.item.audioItem.audioBroadcast"
    }
  }

  public var description: String { sonosObject }

  /// Reads a share link (`https://music.apple.com/ca/album/name/123?i=456`) or a Sonos object
  /// (`song:456`, `album:123`, `playlist:pl.u-…`, `librarytrack:i.…`, `radio:ra.…`).
  public static func parse(_ text: String) -> AppleMusicItem? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if let url = URL(string: trimmed), url.host()?.hasSuffix("music.apple.com") == true {
      return parse(shareLink: url)
    }
    let parts = trimmed.split(separator: ":", maxSplits: 1).map(String.init)
    guard parts.count == 2, !parts[1].isEmpty else { return nil }
    switch parts[0].lowercased() {
    case "song": return .song(parts[1])
    case "album": return .album(parts[1])
    case "playlist": return .playlist(parts[1])
    case "librarytrack": return .libraryTrack(parts[1])
    case "libraryalbum": return .libraryAlbum(parts[1])
    case "libraryplaylist": return .libraryPlaylist(parts[1])
    case "radio": return .station(parts[1])
    default: return nil
    }
  }

  static func parse(shareLink url: URL) -> AppleMusicItem? {
    let components = url.pathComponents.filter { $0 != "/" }
    guard let kindIndex = components.firstIndex(where: { ["album", "song", "playlist", "station"].contains($0) }),
      let last = components.last, kindIndex < components.count - 1
    else { return nil }
    let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    switch components[kindIndex] {
    case "album":
      if let track = query.first(where: { $0.name == "i" })?.value, !track.isEmpty {
        return .song(track)
      }
      return .album(last)
    case "song":
      return .song(last)
    case "playlist":
      return .playlist(last)
    case "station":
      return .station(last)
    default:
      return nil
    }
  }
}

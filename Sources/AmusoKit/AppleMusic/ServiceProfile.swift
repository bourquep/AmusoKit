import Foundation

/// What a household's players write into their Apple Music URIs: the account serial and the
/// flags, learned from items the household already holds.
nonisolated struct ServiceProfile: Sendable, Hashable, Codable {
  var serialNumber: Int?
  var songFlags: Int?
  var libraryTrackFlags: Int?
  var containerFlags: Int?
  /// The Apple Music URIs the profile was learned from, for the record.
  var sampleURIs: [String] = []

  init(
    serialNumber: Int? = nil,
    songFlags: Int? = nil,
    libraryTrackFlags: Int? = nil,
    containerFlags: Int? = nil,
    sampleURIs: [String] = []
  ) {
    self.serialNumber = serialNumber
    self.songFlags = songFlags
    self.libraryTrackFlags = libraryTrackFlags
    self.containerFlags = containerFlags
    self.sampleURIs = sampleURIs
  }

  var isEmpty: Bool {
    serialNumber == nil && songFlags == nil && libraryTrackFlags == nil && containerFlags == nil
  }

  /// The Sonos app's own style when the serial is known, `?sid=204` alone otherwise.
  var preferredStyle: AppleMusicURIStyle {
    if let serialNumber {
      return .sonosApp(
        serial: serialNumber,
        songFlags: songFlags ?? 8224,
        libraryTrackFlags: libraryTrackFlags ?? 8232,
        containerFlags: containerFlags ?? 8300
      )
    }
    return .serviceOnly
  }

  var summary: String {
    "sn=\(serialNumber.map(String.init) ?? "-") songFlags=\(songFlags.map(String.init) ?? "-")"
      + " libraryTrackFlags=\(libraryTrackFlags.map(String.init) ?? "-")"
      + " containerFlags=\(containerFlags.map(String.init) ?? "-")"
  }
}

nonisolated enum ServiceProfileLearner {
  /// Reads the serial and flags out of any Apple Music (`sid=204`) URIs in `uris`.
  static func learn(from uris: some Sequence<String>) -> ServiceProfile {
    var profile = ServiceProfile()
    for uri in uris where uri.contains("sid=204") {
      profile.sampleURIs.append(uri)
      if let match = uri.firstMatch(of: #/sn=(\d+)/#), let serial = Int(match.1) {
        profile.serialNumber = serial
      }
      if let match = uri.firstMatch(of: #/flags=(\d+)/#), let flags = Int(match.1) {
        if uri.hasPrefix("x-rincon-cpcontainer") {
          profile.containerFlags = flags
        } else if uri.contains("librarytrack") {
          profile.libraryTrackFlags = flags
        } else {
          profile.songFlags = flags
        }
      }
    }
    return profile
  }

  /// Every URI with `sid=204` that the coordinator's favorites, queue, Sonos playlists, media
  /// info and position info hold.
  static func appleMusicURIs(coordinator: PlayerEndpoint, client: SoapClient) async -> [String] {
    var uris: [String] = []
    let directory = ContentDirectoryService(client: client, endpoint: coordinator)
    for objectID in ["FV:2", "Q:0", "SQ:"] {
      var start = 0
      while start < 500 {
        guard let page = try? await directory.browse(objectID: objectID, start: start, count: 100) else { break }
        for item in page.items {
          uris.append(contentsOf: item.resources.map(\.uri))
          if let metadata = item.resourceMetadata, let nested = try? DIDLLite.parse(metadata) {
            uris.append(contentsOf: nested.flatMap { $0.resources.map(\.uri) })
          }
        }
        start += page.numberReturned
        if page.numberReturned == 0 || start >= page.totalMatches { break }
      }
    }
    let transport = AVTransportService(client: client, endpoint: coordinator)
    if let media = try? await transport.getMediaInfo() {
      uris.append(media.currentURI)
      uris.append(media.nextURI)
    }
    if let position = try? await transport.getPositionInfo() {
      uris.append(position.uri)
    }
    return uris.filter { $0.contains("sid=204") }
  }

  static func scan(coordinator: PlayerEndpoint, client: SoapClient) async -> ServiceProfile {
    learn(from: await appleMusicURIs(coordinator: coordinator, client: client))
  }
}

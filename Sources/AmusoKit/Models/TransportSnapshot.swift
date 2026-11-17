import Foundation

/// What a group is playing from, read off its `AVTransportURI`.
nonisolated public enum PlaySource: Sendable, Hashable {
  /// The group's own queue, where the app enqueues.
  case queue
  case lineIn
  case television
  /// An Apple Music station (`ra.…`), as the app tunes to one.
  case appleMusicStation(id: String)
  case radio
  /// AirPlay or Bluetooth.
  case stream
  /// A player that follows another group's coordinator.
  case follower(coordinatorUUID: String)
  case nothing
  case other(String)

  public init(transportURI: String) {
    let uri = transportURI.trimmingCharacters(in: .whitespaces)
    if uri.isEmpty {
      self = .nothing
    } else if uri.hasPrefix("x-rincon-queue:") {
      self = .queue
    } else if uri.hasPrefix("x-rincon-stream:") {
      self = .lineIn
    } else if uri.hasPrefix("x-sonos-htastream:") {
      self = .television
    } else if let id = Self.appleMusicStationID(in: uri) {
      self = .appleMusicStation(id: id)
    } else if uri.hasPrefix("x-sonosapi-stream:") || uri.hasPrefix("x-sonosapi-radio:")
      || uri.hasPrefix("x-rincon-mp3radio:") || uri.hasPrefix("x-sonosapi-hls:") {
      self = .radio
    } else if uri.hasPrefix("x-sonos-vli:") {
      self = .stream
    } else if uri.hasPrefix("x-rincon:") {
      self = .follower(coordinatorUUID: String(uri.dropFirst("x-rincon:".count)))
    } else {
      self = .other(uri)
    }
  }

  public var isQueue: Bool {
    self == .queue
  }

  /// The station in `x-sonosapi-radio:radio%3ara.475672?sid=204`.
  static func appleMusicStationID(in uri: String) -> String? {
    let prefix = "x-sonosapi-radio:radio%3a"
    guard uri.hasPrefix(prefix), uri.contains("sid=\(AppleMusicURI.serviceID)") else { return nil }
    let id = uri.dropFirst(prefix.count).prefix { $0 != "?" }
    return id.isEmpty ? nil : String(id)
  }
}

/// The track a group is on.
nonisolated public struct NowPlayingTrack: Sendable, Hashable {
  public var uri: String
  public var title: String
  public var artist: String?
  public var album: String?
  /// The player's own art for the track, such as `/getaa?s=1&u=…`, relative to the player.
  public var albumArtPath: String?
  public var duration: Duration?
  /// 1-based, in the queue.
  public var queueIndex: Int?
  /// What the player is rendering, when an event said.
  public var streamInfo: StreamInfo?

  public init(
    uri: String,
    title: String,
    artist: String? = nil,
    album: String? = nil,
    albumArtPath: String? = nil,
    duration: Duration? = nil,
    queueIndex: Int? = nil,
    streamInfo: StreamInfo? = nil
  ) {
    self.uri = uri
    self.title = title
    self.artist = artist
    self.album = album
    self.albumArtPath = albumArtPath
    self.duration = duration
    self.queueIndex = queueIndex
    self.streamInfo = streamInfo
  }

  /// The track as the player described it in DIDL-Lite.
  public init?(uri: String, metadata: DIDLItem?, queueIndex: Int?) {
    guard let metadata, !metadata.title.isEmpty || !uri.isEmpty else { return nil }
    self.init(
      uri: uri,
      title: metadata.title,
      artist: metadata.creator,
      album: metadata.album,
      albumArtPath: metadata.albumArtURI,
      duration: metadata.resources.first?.durationText.flatMap(SonosTime.duration(from:)),
      queueIndex: queueIndex,
      streamInfo: metadata.streamInfo.flatMap(StreamInfo.init)
    )
  }

  /// The Apple Music catalog song id in a `song%3a123` or `song:123` URI, if it is one.
  public var catalogSongID: String? {
    Self.appleMusicObject(in: uri, kind: "song")
  }

  /// The Apple Music library track id in a `librarytrack%3ai.…` URI, if it is one.
  public var libraryTrackID: String? {
    Self.appleMusicObject(in: uri, kind: "librarytrack")
  }

  static func appleMusicObject(in uri: String, kind: String) -> String? {
    let isAppleMusic = uri.contains("sid=204")
      || uri.hasPrefix("x-sonos-http:\(kind)")
      || uri.hasPrefix("x-sonosapi-hls-static:\(kind)")
    guard isAppleMusic else { return nil }
    for separator in ["\(kind)%3a", "\(kind):"] {
      if let range = uri.range(of: separator) {
        let rest = uri[range.upperBound...]
        let end = rest.firstIndex { $0 == "?" || $0 == "&" } ?? rest.endIndex
        var id = String(rest[..<end])
        if id.hasSuffix(".mp4") {
          id = String(id.dropLast(4))
        }
        return id.isEmpty ? nil : id
      }
    }
    return nil
  }

  /// The player's art as a URL, given the player. The path carries a query (`/getaa?s=1&u=…`)
  /// that must stay one, so it is resolved against the player's base URL rather than appended.
  public func albumArtURL(on endpoint: PlayerEndpoint) -> URL? {
    guard let albumArtPath, !albumArtPath.isEmpty else { return nil }
    if albumArtPath.hasPrefix("http") {
      return URL(string: albumArtPath)
    }
    return URL(string: albumArtPath, relativeTo: endpoint.baseURL)?.absoluteURL
  }
}

/// A position read from the player at a moment, so that the app can count forward from it.
nonisolated public struct PositionClock: Sendable, Hashable {
  public var relativeTime: Duration
  public var observedAt: ContinuousClock.Instant

  public init(relativeTime: Duration, observedAt: ContinuousClock.Instant = .now) {
    self.relativeTime = relativeTime
    self.observedAt = observedAt
  }

  /// Where playback is now, counting from the reading while playing.
  public func position(at now: ContinuousClock.Instant = .now, playing: Bool) -> Duration {
    playing ? relativeTime + observedAt.duration(to: now) : relativeTime
  }
}

/// What the group is doing, as `AVTransport` last said.
nonisolated public struct TransportSnapshot: Sendable, Hashable {
  public var state: TransportState = .unknown
  public var source: PlaySource = .nothing
  public var track: NowPlayingTrack?
  public var position: PositionClock?
  public var playMode: PlayMode = .normal
  public var numberOfTracks: Int = 0
  /// 1-based, 0 when nothing is loaded.
  public var currentTrackNumber: Int = 0

  public init() {}

  public var isPlaying: Bool {
    state == .playing || state == .transitioning
  }

  /// The snapshot after `AVTransport`'s `LastChange` variables; what the event does not mention
  /// is kept.
  public func applying(lastChange variables: [String: String]) -> TransportSnapshot {
    var next = self
    if let state = variables["TransportState"] {
      next.state = TransportState(sonosValue: state)
    }
    if let uri = variables["AVTransportURI"] {
      next.source = PlaySource(transportURI: uri)
    }
    if let mode = variables["CurrentPlayMode"].flatMap(PlayMode.init(rawValue:)) {
      next.playMode = mode
    }
    if let count = variables["NumberOfTracks"].flatMap(Int.init) {
      next.numberOfTracks = count
    }
    if let number = variables["CurrentTrack"].flatMap(Int.init) {
      next.currentTrackNumber = number
    }
    if variables["CurrentTrackURI"] != nil || variables["CurrentTrackMetaData"] != nil {
      let uri = variables["CurrentTrackURI"] ?? next.track?.uri ?? ""
      let metadata = variables["CurrentTrackMetaData"].flatMap { try? DIDLLite.parse($0).first }
      var track = NowPlayingTrack(uri: uri, metadata: metadata, queueIndex: next.currentTrackNumber)
      if track == nil, !uri.isEmpty {
        track = NowPlayingTrack(uri: uri, title: next.track?.title ?? "", queueIndex: next.currentTrackNumber)
      }
      if let duration = variables["CurrentTrackDuration"].flatMap(SonosTime.duration(from:)) {
        track?.duration = duration
      }
      if track?.uri != next.track?.uri {
        next.position = nil
      }
      next.track = uri.isEmpty && metadata == nil ? nil : track
    } else if let duration = variables["CurrentTrackDuration"].flatMap(SonosTime.duration(from:)) {
      next.track?.duration = duration
    }
    return next
  }
}

/// A member's own volume.
nonisolated public struct MemberVolume: Sendable, Hashable {
  public var volume: Int
  public var muted: Bool

  public init(volume: Int, muted: Bool) {
    self.volume = volume
    self.muted = muted
  }
}

/// The group's volume and its members'.
nonisolated public struct VolumeSnapshot: Sendable, Hashable {
  public var groupVolume: Int?
  public var groupMuted: Bool?
  /// By player UUID.
  public var members: [String: MemberVolume] = [:]

  public init(groupVolume: Int? = nil, groupMuted: Bool? = nil, members: [String: MemberVolume] = [:]) {
    self.groupVolume = groupVolume
    self.groupMuted = groupMuted
    self.members = members
  }
}

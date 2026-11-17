import Foundation

/// What `AVTransport` says a group is doing.
nonisolated public enum TransportState: String, Sendable, Hashable, CaseIterable {
  case playing = "PLAYING"
  case paused = "PAUSED_PLAYBACK"
  case stopped = "STOPPED"
  case transitioning = "TRANSITIONING"
  case noMedia = "NO_MEDIA_PRESENT"
  case unknown = "UNKNOWN"

  public init(sonosValue: String) {
    self = TransportState(rawValue: sonosValue) ?? .unknown
  }
}

nonisolated struct TransportInfo: Sendable, Hashable {
  var state: TransportState
  var status: String
  var speed: String
}

nonisolated struct PositionInfo: Sendable, Hashable {
  /// 1-based index in the queue, 0 when nothing is loaded.
  var track: Int
  var durationText: String
  var duration: Duration?
  var uri: String
  var metadataXML: String
  var metadata: DIDLItem?
  var relativeTimeText: String
  var relativeTime: Duration?
}

nonisolated struct MediaInfo: Sendable, Hashable {
  var numberOfTracks: Int
  var currentURI: String
  var currentURIMetadata: String
  var nextURI: String
}

nonisolated struct QueueAddResult: Sendable, Hashable {
  var firstTrackNumberEnqueued: Int
  var numberOfTracksAdded: Int
  var newQueueLength: Int
}

/// Sonos writes times as `H:MM:SS`, sometimes with milliseconds, and `NOT_IMPLEMENTED` where it
/// has none.
nonisolated public enum SonosTime {
  public static func duration(from text: String) -> Duration? {
    let parts = text.split(separator: ":")
    guard parts.count == 3, let hours = Int(parts[0]), let minutes = Int(parts[1]) else {
      return nil
    }
    let secondsParts = parts[2].split(separator: ".")
    guard let first = secondsParts.first, let seconds = Int(first) else { return nil }
    var result = Duration.seconds(hours * 3600 + minutes * 60 + seconds)
    if secondsParts.count > 1, let fraction = Double("0.\(secondsParts[1])") {
      result += .milliseconds(Int(fraction * 1000))
    }
    return result
  }

  public static func text(from duration: Duration) -> String {
    let total = Int(duration.components.seconds)
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let seconds = total % 60
    return "\(hours):\(minutes < 10 ? "0" : "")\(minutes):\(seconds < 10 ? "0" : "")\(seconds)"
  }
}

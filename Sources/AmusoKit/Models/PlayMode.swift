import Foundation

nonisolated public enum RepeatMode: String, Sendable, Hashable, CaseIterable {
  case off
  case all
  case one
}

/// `AVTransport`'s play mode: shuffle and repeat in one word.
nonisolated public enum PlayMode: String, Sendable, Hashable, CaseIterable {
  case normal = "NORMAL"
  case repeatAll = "REPEAT_ALL"
  case repeatOne = "REPEAT_ONE"
  case shuffleNoRepeat = "SHUFFLE_NOREPEAT"
  case shuffle = "SHUFFLE"
  case shuffleRepeatOne = "SHUFFLE_REPEAT_ONE"

  public var isShuffled: Bool {
    switch self {
    case .shuffleNoRepeat, .shuffle, .shuffleRepeatOne: true
    case .normal, .repeatAll, .repeatOne: false
    }
  }

  public var repeatMode: RepeatMode {
    switch self {
    case .normal, .shuffleNoRepeat: .off
    case .repeatAll, .shuffle: .all
    case .repeatOne, .shuffleRepeatOne: .one
    }
  }

  public static func mode(shuffled: Bool, repeating: RepeatMode) -> PlayMode {
    switch (shuffled, repeating) {
    case (false, .off): .normal
    case (false, .all): .repeatAll
    case (false, .one): .repeatOne
    case (true, .off): .shuffleNoRepeat
    case (true, .all): .shuffle
    case (true, .one): .shuffleRepeatOne
    }
  }
}

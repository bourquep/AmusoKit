import Foundation

/// Finds the household through whichever player answers first.
///
/// Any one player describes the whole household, so the players known from before are asked a
/// little apart, without waiting for an answer, and Bonjour browses at the same time; the players
/// it finds are asked as well. The first household with groups wins and the other requests are
/// cancelled. A player that does not answer (unplugged, a portable one asleep, an address that
/// moved) holds up no other: tried one after another, each cost a request's whole timeout before
/// the next was asked (README, _How it talks to the players_).
nonisolated public enum HouseholdSearch {
  public struct Outcome: Sendable {
    public var household: Household?
    /// The last Sonos error seen, for the status when no household was found.
    public var lastError: SonosError?
    /// The player that answered.
    public var endpoint: PlayerEndpoint?
  }

  private enum Step: Sendable {
    case found(Household, PlayerEndpoint)
    case failed(PlayerEndpoint, SonosError?)
    case discovered([PlayerEndpoint])
  }

  /// - Parameters:
  ///   - known: the players seen before, the likeliest to answer first.
  ///   - stagger: how long after a player the next one is asked.
  ///   - discover: the players Bonjour finds.
  ///   - household: asks one player for the household.
  public static func first(
    known: [PlayerEndpoint],
    stagger: Duration = .milliseconds(250),
    discover: @escaping @Sendable () async -> [PlayerEndpoint],
    household: @escaping @Sendable (PlayerEndpoint) async throws -> Household
  ) async -> Outcome {
    await withTaskGroup(of: Step.self) { group in
      var asked = Set<PlayerEndpoint>()
      // Each batch is staggered from when it arrives: Bonjour's players come after its browse.
      func ask(_ endpoints: [PlayerEndpoint]) {
        var index = 0
        for endpoint in endpoints where !asked.contains(endpoint) {
          let delay = stagger * index
          index += 1
          asked.insert(endpoint)
          group.addTask {
            do {
              try await Task.sleep(for: delay)
              return .found(try await household(endpoint), endpoint)
            } catch {
              return .failed(endpoint, error as? SonosError)
            }
          }
        }
      }
      ask(known)
      group.addTask { .discovered(await discover()) }
      var outcome = Outcome()
      while let step = await group.next() {
        switch step {
        case .found(let found, let endpoint) where !found.groups.isEmpty:
          group.cancelAll()
          return Outcome(household: found, lastError: nil, endpoint: endpoint)
        case .found:
          break
        case .failed(_, let error):
          if let error {
            outcome.lastError = error
          }
        case .discovered(let endpoints):
          ask(endpoints)
        }
      }
      return outcome
    }
  }
}

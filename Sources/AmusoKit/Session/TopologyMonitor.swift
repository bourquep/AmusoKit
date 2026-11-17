import Foundation
import Observation

/// The household as the players report it, kept current through `ZoneGroupTopology` events on
/// one player, with a poll as the fallback.
@Observable
@MainActor
public final class TopologyMonitor {
  public private(set) var household: Household
  public private(set) var isSubscribed = false
  public private(set) var lastUpdate: Date?

  private let client: SoapClient
  private let gena: GenaClient
  private let listener: EventListener?
  private var subscription: GenaSubscription?
  private var renewal: Task<Void, Never>?
  private var polling: Task<Void, Never>?

  public init(household: Household, client: SoapClient, gena: GenaClient, listener: EventListener?) {
    self.household = household
    self.client = client
    self.gena = gena
    self.listener = listener
  }

  /// The player events are subscribed on: any visible one.
  public var reporter: Player? {
    household.groups.first?.coordinator ?? household.players.first
  }

  /// Subscribes to topology events through `callback`, or polls every `pollInterval` when there
  /// is no listener.
  public func start(callback: URL?, pollInterval: Duration = .seconds(30)) async {
    guard let reporter else { return }
    if let callback, listener != nil {
      do {
        let subscription = try await gena.subscribe(to: .zoneGroupTopology, on: reporter.endpoint, callback: callback)
        self.subscription = subscription
        isSubscribed = true
        scheduleRenewal(subscription)
        return
      } catch {
        isSubscribed = false
      }
    }
    polling = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: pollInterval)
        await self?.refresh()
      }
    }
  }

  public func stop() async {
    renewal?.cancel()
    polling?.cancel()
    if let subscription {
      try? await gena.unsubscribe(subscription)
    }
    subscription = nil
    isSubscribed = false
  }

  /// Back from the background: reads the household again and subscribes afresh through
  /// `callback`, or polls.
  public func resume(callback: URL?) async {
    renewal?.cancel()
    polling?.cancel()
    if let subscription {
      let gena = gena
      Task { try? await gena.unsubscribe(subscription) }
    }
    subscription = nil
    isSubscribed = false
    await refresh()
    await start(callback: callback)
  }

  /// Whether a notification is this monitor's.
  public func owns(_ notification: GenaNotification) -> Bool {
    notification.sid == subscription?.sid
  }

  /// Applies a `ZoneGroupTopology` notification.
  public func apply(_ notification: GenaNotification) {
    guard owns(notification), let event = try? GenaEventParser.parse(notification.body),
      let state = event.properties["ZoneGroupState"], !state.isEmpty,
      let parsed = try? ZoneGroupTopologyService.parse(zoneGroupState: state)
    else { return }
    update(with: parsed)
  }

  public func refresh() async {
    guard let reporter else { return }
    if let fetched = try? await ZoneGroupTopologyService(client: client, endpoint: reporter.endpoint).household() {
      update(with: fetched)
    }
  }

  /// Keeps the device descriptions already fetched for players that are still there.
  private func update(with fetched: Household) {
    var descriptions: [String: DeviceDescription] = [:]
    for player in household.players {
      descriptions[player.uuid] = player.deviceDescription
    }
    var next = fetched
    for groupIndex in next.groups.indices {
      for memberIndex in next.groups[groupIndex].members.indices {
        let uuid = next.groups[groupIndex].members[memberIndex].uuid
        if next.groups[groupIndex].members[memberIndex].deviceDescription == nil {
          next.groups[groupIndex].members[memberIndex].deviceDescription = descriptions[uuid]
        }
      }
    }
    household = next
    lastUpdate = .now
  }

  private func scheduleRenewal(_ subscription: GenaSubscription) {
    renewal?.cancel()
    renewal = Task { [weak self] in
      try? await Task.sleep(for: subscription.renewalDelay)
      guard !Task.isCancelled, let self else { return }
      if let renewed = try? await gena.renew(subscription) {
        self.subscription = renewed
        scheduleRenewal(renewed)
      } else {
        isSubscribed = false
      }
    }
  }
}

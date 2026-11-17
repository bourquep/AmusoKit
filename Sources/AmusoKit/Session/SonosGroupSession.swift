import Foundation
import Observation

/// One group, live: its transport and volume as the players report them, and the commands that
/// change them. Events come first; polling fills in where they cannot (README, _How it talks to the
/// players_).
@Observable
@MainActor
public final class SonosGroupSession {
  public enum Feed: Sendable, Hashable {
    case events
    case polling
    case stopped
  }

  public private(set) var group: ZoneGroup
  public internal(set) var transport = TransportSnapshot()
  public internal(set) var volume = VolumeSnapshot()
  public private(set) var feed: Feed = .stopped
  /// Bumped when the queue changed on the player, for whoever shows it.
  public internal(set) var queueVersion = 0
  public internal(set) var lastError: SonosError?
  /// Whether the transport has been read once, so that an empty one means nothing plays rather
  /// than nothing known yet.
  public internal(set) var hasReadState = false
  /// Bumped by each `replaceQueue`, so that a fill still under way stops adding to a queue that
  /// is no longer its own.
  @ObservationIgnored var queueFillGeneration = 0
  /// The fills under way, by the number `beginQueueFill` gave them, and how far each has got.
  var queueFills: [Int: QueueFillProgress] = [:]
  @ObservationIgnored var lastQueueFillID = 0
  /// How far the fills under way have got, together; `nil` when none is. A queue replaced drops
  /// the fills it stopped, so that their songs don't count.
  public var queueFillProgress: QueueFillProgress? {
    guard !queueFills.isEmpty else { return nil }
    return queueFills.values.reduce(into: QueueFillProgress(total: 0)) { sum, fill in
      sum.processed += fill.processed
      sum.total += fill.total
    }
  }
  /// Where each queue fill is recorded, call by call, for a host app's diagnostics.
  @ObservationIgnored public let fillJournal: QueueFillJournal

  let client: SoapClient
  private let gena: GenaClient
  private let listener: EventListener?
  private var subscriptions: [String: GenaSubscription] = [:]
  private var renewals: [String: Task<Void, Never>] = [:]
  private var poller: Task<Void, Never>?
  private var positionResync: Task<Void, Never>?
  var settle: Task<Void, Never>?
  private let positionResyncInterval: Duration
  /// Where the players send their events, kept to subscribe again while polling.
  private var callback: URL?

  /// Whether the app is in the background, where polling slows down (`pollInterval`).
  public var isInBackground = false {
    didSet {
      guard isInBackground != oldValue, feed == .polling else { return }
      startPolling()
    }
  }

  public init(
    group: ZoneGroup,
    client: SoapClient,
    gena: GenaClient,
    listener: EventListener?,
    fillJournal: QueueFillJournal = QueueFillJournal(),
    positionResyncInterval: Duration = .seconds(30)
  ) {
    self.group = group
    self.fillJournal = fillJournal
    self.client = client
    self.gena = gena
    self.listener = listener
    self.positionResyncInterval = positionResyncInterval
  }

  public var coordinator: Player? {
    group.coordinator
  }

  var coordinatorEndpoint: PlayerEndpoint? {
    coordinator?.endpoint
  }

  var avTransport: AVTransportService? {
    coordinatorEndpoint.map { AVTransportService(client: client, endpoint: $0) }
  }

  var groupRendering: GroupRenderingControlService? {
    coordinatorEndpoint.map { GroupRenderingControlService(client: client, endpoint: $0) }
  }

  /// Where playback is now.
  public var currentPosition: Duration? {
    transport.position?.position(playing: transport.state == .playing)
  }

  // MARK: Lifecycle

  /// Reads the state, then subscribes to the players' events through `callback`, or polls.
  public func start(callback: URL?) async {
    self.callback = callback
    await refreshAll()
    if let callback, listener != nil {
      await subscribeAll(callback: callback)
    }
    if subscriptions.isEmpty {
      startPolling()
    } else {
      feed = .events
    }
    schedulePositionResync()
  }

  public func stop() async {
    poller?.cancel()
    positionResync?.cancel()
    settle?.cancel()
    for task in renewals.values {
      task.cancel()
    }
    renewals.removeAll()
    for subscription in subscriptions.values {
      try? await gena.unsubscribe(subscription)
    }
    subscriptions.removeAll()
    feed = .stopped
  }

  /// The group as the topology now has it. A new coordinator means new subscriptions.
  public func update(group newGroup: ZoneGroup, callback: URL?) async {
    let coordinatorChanged = newGroup.coordinatorUUID != group.coordinatorUUID
    let membersChanged = Set(newGroup.members.map(\.uuid)) != Set(group.members.map(\.uuid))
    group = newGroup
    guard coordinatorChanged || membersChanged else { return }
    await stop()
    await start(callback: callback)
  }

  // MARK: Events

  public func owns(_ notification: GenaNotification) -> Bool {
    subscriptions[notification.sid] != nil
  }

  /// Applies a notification from one of this session's subscriptions.
  public func apply(_ notification: GenaNotification) {
    guard let subscription = subscriptions[notification.sid],
      let event = try? GenaEventParser.parse(notification.body)
    else { return }
    switch subscription.service {
    case .avTransport:
      applyTransport(event)
    case .renderingControl:
      applyMemberVolume(event, of: subscription.endpointUUID(in: group))
    case .groupRenderingControl:
      if let value = event.properties["GroupVolume"].flatMap(Int.init) {
        volume.groupVolume = value
      }
      if let muted = event.properties["GroupMute"] {
        volume.groupMuted = muted == "1"
      }
    case .contentDirectory:
      if let updates = event.properties["ContainerUpdateIDs"], updates.contains("Q:0") {
        queueVersion += 1
      }
    case .zoneGroupTopology, .deviceProperties:
      break
    }
  }

  private func applyTransport(_ event: GenaEvent) {
    let before = transport
    transport = transport.applying(lastChange: event.lastChange)
    settle?.cancel()
    if transport.track?.uri != before.track?.uri || transport.state != before.state {
      Task { await resyncPosition() }
    }
  }

  private func applyMemberVolume(_ event: GenaEvent, of uuid: String) {
    var member = volume.members[uuid] ?? MemberVolume(volume: 0, muted: false)
    if let value = event["Volume"].flatMap(Int.init) {
      member.volume = value
    }
    if let muted = event["Mute"] {
      member.muted = muted == "1"
    }
    volume.members[uuid] = member
  }

  // MARK: Plumbing

  func transportCommand(
    expecting state: TransportState?, _ command: (AVTransportService) async throws -> Void
  ) async {
    guard let avTransport else { return }
    if state != nil {
      transport.state = .transitioning
    }
    do {
      try await command(avTransport)
      lastError = nil
    } catch {
      record(error)
      await refreshTransport()
      return
    }
    await settleAfterCommand(expecting: state)
  }

  /// Waits for an event to confirm a command; reads the state back when none comes.
  func settleAfterCommand(expecting state: TransportState?) async {
    settle?.cancel()
    settle = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(1500))
      guard !Task.isCancelled, let self else { return }
      await refreshTransport()
    }
  }

  func record(_ error: any Error) {
    lastError = (error as? SonosError) ?? .invalidResponse(error.localizedDescription)
  }

  private func subscribeAll(callback: URL) async {
    guard let coordinatorEndpoint else { return }
    var wanted: [(UPnPService, PlayerEndpoint)] = [
      (.avTransport, coordinatorEndpoint),
      (.groupRenderingControl, coordinatorEndpoint),
      (.contentDirectory, coordinatorEndpoint)
    ]
    for member in group.visibleMembers {
      wanted.append((.renderingControl, member.endpoint))
    }
    // All at once: a member that does not answer holds up none of the others.
    let gena = gena
    let results = await withTaskGroup(of: Result<GenaSubscription, any Error>.self) { group in
      for (service, endpoint) in wanted {
        group.addTask {
          do {
            return .success(try await gena.subscribe(to: service, on: endpoint, callback: callback))
          } catch {
            return .failure(error)
          }
        }
      }
      var results: [Result<GenaSubscription, any Error>] = []
      for await result in group {
        results.append(result)
      }
      return results
    }
    for result in results {
      switch result {
      case .success(let subscription):
        subscriptions[subscription.sid] = subscription
        scheduleRenewal(subscription)
      case .failure(let error):
        record(error)
      }
    }
  }

  private func scheduleRenewal(_ subscription: GenaSubscription) {
    renewals[subscription.sid]?.cancel()
    renewals[subscription.sid] = Task { [weak self] in
      try? await Task.sleep(for: subscription.renewalDelay)
      guard !Task.isCancelled, let self else { return }
      if let renewed = try? await gena.renew(subscription) {
        subscriptions[subscription.sid] = renewed
        scheduleRenewal(renewed)
        return
      }
      subscriptions[subscription.sid] = nil
      // The player may have forgotten the subscription (a restart, a network change): a fresh
      // one is asked for before the session falls back to polling for that service's state.
      if let callback, isListening,
        let fresh = try? await gena.subscribe(to: subscription.service, on: subscription.endpoint, callback: callback) {
        subscriptions[fresh.sid] = fresh
        scheduleRenewal(fresh)
      } else if subscriptions.isEmpty {
        startPolling()
      }
    }
  }
}

// MARK: Polling

extension SonosGroupSession {
  /// How often the state is read while there are no events: every second in front, every five in
  /// the background, where only the lock screen shows it and the app runs only while the room
  /// plays (README, _How it talks to the players_).
  static let foregroundPollInterval: Duration = .seconds(1)
  static let backgroundPollInterval: Duration = .seconds(5)
  /// How often polling tries to have events again.
  static let resubscribeInterval: Duration = .seconds(60)

  var pollInterval: Duration {
    isInBackground ? Self.backgroundPollInterval : Self.foregroundPollInterval
  }

  /// Whether events can arrive: there is a listener and it has not failed.
  private var isListening: Bool {
    guard let listener else { return false }
    return !listener.hasFailed
  }

  /// Reads the state every `pollInterval`, the volumes every third time, and every
  /// `resubscribeInterval` tries to subscribe again, which ends the polling when it works: a lapse
  /// of a moment is no reason to poll for the rest of the session.
  private func startPolling() {
    poller?.cancel()
    feed = .polling
    let interval = pollInterval
    poller = Task { [weak self] in
      let clock = ContinuousClock()
      var lastResubscribe = clock.now
      var tick = 0
      while !Task.isCancelled {
        try? await Task.sleep(for: interval)
        guard let self, !Task.isCancelled else { return }
        await refreshTransport()
        tick += 1
        if tick % 3 == 0 {
          await refreshVolumes()
        }
        if lastResubscribe.duration(to: clock.now) >= Self.resubscribeInterval, let callback, isListening {
          lastResubscribe = clock.now
          await subscribeAll(callback: callback)
          if !subscriptions.isEmpty, !Task.isCancelled {
            feed = .events
            return
          }
        }
      }
    }
  }

  private func schedulePositionResync() {
    positionResync?.cancel()
    let interval = positionResyncInterval
    positionResync = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: interval)
        guard let self else { return }
        guard transport.state == .playing else { continue }
        await resyncWhilePlaying()
      }
    }
  }
}

// MARK: Resuming

extension SonosGroupSession {
  /// Back from the background: reads the state again and subscribes afresh through `callback`,
  /// since iOS may have kept the app suspended past the subscriptions' timeout, or taken the
  /// listener's socket. Polls when no subscription holds.
  public func resume(callback: URL?) async {
    self.callback = callback
    for task in renewals.values {
      task.cancel()
    }
    renewals.removeAll()
    let lapsed = Array(subscriptions.values)
    subscriptions.removeAll()
    // Best effort, and not waited for: most have lapsed already.
    let gena = gena
    Task {
      for subscription in lapsed {
        try? await gena.unsubscribe(subscription)
      }
    }
    await refreshAll()
    if let callback, listener != nil {
      await subscribeAll(callback: callback)
    }
    if subscriptions.isEmpty {
      startPolling()
    } else {
      poller?.cancel()
      feed = .events
    }
  }
}

extension GenaSubscription {
  /// The UUID of the player this subscription is on, within the group.
  func endpointUUID(in group: ZoneGroup) -> String {
    group.members.first { $0.endpoint == endpoint }?.uuid ?? endpoint.host
  }
}

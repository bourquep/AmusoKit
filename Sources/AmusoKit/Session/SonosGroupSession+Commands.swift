import Foundation

// MARK: Commands

extension SonosGroupSession {
  public func play() async {
    await transportCommand(expecting: .playing) { try await $0.play() }
  }

  public func pause() async {
    await transportCommand(expecting: .paused) { try await $0.pause() }
  }

  public func stopPlayback() async {
    await transportCommand(expecting: .stopped) { try await $0.stop() }
  }

  public func togglePlayPause() async {
    if transport.state == .playing || transport.state == .transitioning {
      await pause()
    } else {
      await play()
    }
  }

  public func next() async {
    await transportCommand(expecting: nil) { try await $0.next() }
  }

  public func previous() async {
    await transportCommand(expecting: nil) { try await $0.previous() }
  }

  public func seek(to time: Duration) async {
    transport.position = PositionClock(relativeTime: time)
    await transportCommand(expecting: nil) { try await $0.seek(to: time) }
  }

  public func seek(toTrack number: Int) async {
    await transportCommand(expecting: nil) { try await $0.seek(toTrack: number) }
  }

  public func setPlayMode(_ mode: PlayMode) async {
    transport.playMode = mode
    await transportCommand(expecting: nil) { try await $0.setPlayMode(mode.rawValue) }
  }

  public func setGroupVolume(_ value: Int) async {
    guard let groupRendering else { return }
    volume.groupVolume = max(0, min(100, value))
    do {
      try await groupRendering.setGroupVolume(value)
    } catch {
      record(error)
    }
  }

  public func setGroupMute(_ muted: Bool) async {
    guard let groupRendering else { return }
    volume.groupMuted = muted
    do {
      try await groupRendering.setGroupMute(muted)
    } catch {
      record(error)
    }
  }

  public func setVolume(_ value: Int, of memberUUID: String) async {
    guard let member = group.members.first(where: { $0.uuid == memberUUID }) else { return }
    volume.members[memberUUID] = MemberVolume(
      volume: max(0, min(100, value)), muted: volume.members[memberUUID]?.muted ?? false)
    do {
      try await RenderingControlService(client: client, endpoint: member.endpoint).setVolume(value)
    } catch {
      record(error)
    }
  }

  /// Replaces the queue with `items` and plays from `startIndex` (1-based). Playback starts as
  /// soon as the batch holding `startIndex` is in; the rest follows while it plays. Until then a
  /// failed batch throws; after, the fill goes on, and the outcome says how many were left out.
  /// Items the player refuses are left out (`QueueFillOutcome.refused`), and playback starts at
  /// the next one when the one at `startIndex` is among them.
  ///
  /// The queue plays in `playMode`. Its unshuffled form is set before playback starts, so that a
  /// player left in shuffle by the last queue neither starts on a track of its own choosing nor
  /// shuffles the first batches while the rest goes in; shuffle, when wanted, is set once the
  /// fill is done, over the whole queue.
  @discardableResult
  public func replaceQueue(
    with items: [EnqueueItem], startIndex: Int = 1, playMode: PlayMode = .normal
  ) async throws -> QueueFillOutcome {
    let startIndex = min(max(startIndex, 1), items.count)
    return try await journaling(.replace(startIndex: startIndex, playMode: playMode), of: items) { didCall in
      try await fillQueue(with: items, startIndex: startIndex, playMode: playMode, didCall: didCall)
    }
  }

  private func fillQueue(
    with items: [EnqueueItem], startIndex: Int, playMode: PlayMode,
    didCall: @escaping (QueueFillRecord.Call) -> Void
  ) async throws -> QueueFillOutcome {
    guard let avTransport, let coordinator else { throw SonosError.notFound("coordinator") }
    let fill = beginQueueFill(replacing: true, count: items.count)
    defer { endQueueFill(fill) }
    try await avTransport.stop()
    try await avTransport.removeAllTracksFromQueue()
    transport.state = .transitioning
    let startMode = PlayMode.mode(shuffled: false, repeating: playMode.repeatMode)
    var filler = queueFiller(avTransport, fill: fill, asNext: false)
    filler.didCall = didCall
    filler.requiredAreIn = { position in
      try await avTransport.useQueue(coordinatorUUID: coordinator.uuid)
      // Not worth failing the fill over: the player then keeps the mode it was in.
      try? await avTransport.setPlayMode(startMode.rawValue)
      // Even to the first: a cleared queue keeps the last one's track number, and plays from
      // there without a seek.
      try await avTransport.seek(toTrack: position)
      try await avTransport.play()
    }
    let outcome = try await filler.fill(items, knownLength: 0, required: startIndex)
    if outcome.added > 0 {
      // A fill that another replaced leaves the play mode to that one.
      if !outcome.wasSuperseded {
        transport.playMode = startMode
        if playMode != startMode {
          await setPlayMode(playMode)
          return outcome
        }
      }
      await settleAfterCommand(expecting: .playing)
    } else {
      await refreshTransport()
    }
    return outcome
  }

  /// Points the group at a station and plays it. The queue is left as it was; switching back to
  /// it (`play(queueIndex:)`) picks it up again.
  public func tune(to item: EnqueueItem) async throws {
    guard let avTransport else { throw SonosError.notFound("coordinator") }
    transport.state = .transitioning
    try await avTransport.setAVTransportURI(item.uri, metadata: item.metadata)
    try await avTransport.play()
    await settleAfterCommand(expecting: .playing)
  }

  /// Plays the track at `index` (1-based) of the queue.
  public func play(queueIndex index: Int) async {
    guard let avTransport, let coordinator else { return }
    transport.state = .transitioning
    do {
      if !transport.source.isQueue {
        try await avTransport.useQueue(coordinatorUUID: coordinator.uuid)
      }
      try await avTransport.seek(toTrack: index)
      try await avTransport.play()
      lastError = nil
    } catch {
      record(error)
      await refreshTransport()
      return
    }
    await settleAfterCommand(expecting: .playing)
  }

  /// Removes the track at `index` (1-based) from the queue.
  public func removeFromQueue(index: Int) async throws {
    guard let avTransport else { throw SonosError.notFound("coordinator") }
    try await avTransport.removeTrackFromQueue(index: index)
    queueVersion += 1
  }

  /// Adds `items` to the queue, sixteen per call; `asNext` puts them after the current track. A
  /// failed first batch throws; after it, the fill goes on, and the outcome says how many were
  /// left out.
  @discardableResult
  public func enqueue(
    _ items: [EnqueueItem], position: Int = 0, asNext: Bool = false
  ) async throws -> QueueFillOutcome {
    try await journaling(.add(asNext: asNext), of: items) { didCall in
      guard let avTransport else { throw SonosError.notFound("coordinator") }
      let fill = beginQueueFill(replacing: false, count: items.count)
      defer { endQueueFill(fill) }
      var filler = queueFiller(avTransport, fill: fill, asNext: asNext)
      filler.didCall = didCall
      return try await filler.fill(items, position: position, asNext: asNext, required: min(1, items.count))
    }
  }

  public func clearQueue() async throws {
    guard let avTransport else { throw SonosError.notFound("coordinator") }
    try await avTransport.removeAllTracksFromQueue()
    queueVersion += 1
  }

}

extension SonosGroupSession {
  /// Sixteen items per call, the most `AddMultipleURIsToQueue` takes.
  static func batches(of items: [EnqueueItem], size: Int = 16) -> [[EnqueueItem]] {
    QueueFiller.batches(of: items, size: size)
  }

  /// Runs a fill and records it in `fillJournal`: each call `fill` reports to the closure it is
  /// given, then the outcome, or the error thrown.
  func journaling(
    _ kind: QueueFillRecord.Kind,
    of items: [EnqueueItem],
    _ fill: (_ didCall: @escaping (QueueFillRecord.Call) -> Void) async throws -> QueueFillOutcome
  ) async throws -> QueueFillOutcome {
    let journal = fillJournal
    let id = journal.begin(room: group.name, kind: kind, itemCount: items.count)
    let start = ContinuousClock.now
    do {
      let outcome = try await fill { call in journal.record(call, in: id) }
      journal.end(id, .finished(outcome), after: .now - start)
      return outcome
    } catch {
      let error = (error as? SonosError) ?? .invalidResponse(error.localizedDescription)
      journal.end(id, .failed(error), after: .now - start)
      throw error
    }
  }

  /// A queue fill under way: its number, for its progress, and the generation it belongs to.
  struct QueueFillTicket {
    let id: Int
    let generation: Int
  }

  /// Starts a queue fill of `count` items, which stops any fill under way when `replacing`. The
  /// ticket says whether it is still the one wanted (a queue replaced since takes none of an
  /// earlier fill's batches) and where its progress goes, until `endQueueFill`.
  func beginQueueFill(replacing: Bool, count: Int) -> QueueFillTicket {
    if replacing {
      queueFillGeneration += 1
      // The fills it stops add nothing more to the queue, so their progress no longer counts.
      queueFills.removeAll()
    }
    lastQueueFillID += 1
    let ticket = QueueFillTicket(id: lastQueueFillID, generation: queueFillGeneration)
    queueFills[ticket.id] = QueueFillProgress(total: count)
    return ticket
  }

  func isCurrent(_ fill: QueueFillTicket) -> Bool {
    queueFillGeneration == fill.generation
  }

  /// Sets how far `fill` has got, while it still counts.
  func progress(_ fill: QueueFillTicket, processed: Int) {
    queueFills[fill.id]?.processed = processed
  }

  func endQueueFill(_ fill: QueueFillTicket) {
    queueFills[fill.id] = nil
  }

  /// A filler that adds to the coordinator's queue for `fill`: one item by `AddURIToQueue`, more
  /// by `AddMultipleURIsToQueue`.
  func queueFiller(_ avTransport: AVTransportService, fill: QueueFillTicket, asNext: Bool) -> QueueFiller {
    let contentDirectory = ContentDirectoryService(client: client, endpoint: avTransport.endpoint)
    return QueueFiller(
      add: { batch, position in
        if batch.count == 1, let only = batch.first {
          try await avTransport.addURIToQueue(only, position: position, asNext: asNext)
        } else {
          try await avTransport.addMultipleURIsToQueue(batch, position: position, asNext: asNext)
        }
      },
      readQueueLength: { try await contentDirectory.queueLength() },
      didAdd: { [weak self] in self?.queueVersion += 1 },
      isCurrent: { [weak self] in self?.isCurrent(fill) ?? false },
      didProgress: { [weak self] processed in self?.progress(fill, processed: processed) }
    )
  }
}

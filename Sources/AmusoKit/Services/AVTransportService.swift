import Foundation

/// Transport and queue commands, sent to a group's coordinator.
nonisolated struct AVTransportService: Sendable {
  let client: SoapClient
  let endpoint: PlayerEndpoint

  @discardableResult
  private func call(
    _ name: String,
    _ arguments: [(name: String, value: String)] = [],
    timeout: SoapAction.Timeout = .standard
  ) async throws -> SoapResponse {
    try await client.call(
      SoapAction(
        service: .avTransport, name: name, arguments: [(name: "InstanceID", value: "0")] + arguments,
        timeout: timeout),
      on: endpoint
    )
  }

  func getTransportInfo() async throws -> TransportInfo {
    let response = try await call("GetTransportInfo")
    return TransportInfo(
      state: TransportState(sonosValue: try response.require("CurrentTransportState")),
      status: response["CurrentTransportStatus"] ?? "",
      speed: response["CurrentSpeed"] ?? ""
    )
  }

  func getPositionInfo() async throws -> PositionInfo {
    let response = try await call("GetPositionInfo")
    let metadataXML = response["TrackMetaData"] ?? ""
    let durationText = response["TrackDuration"] ?? ""
    let relativeText = response["RelTime"] ?? ""
    return PositionInfo(
      track: response.int("Track") ?? 0,
      durationText: durationText,
      duration: SonosTime.duration(from: durationText),
      uri: response["TrackURI"] ?? "",
      metadataXML: metadataXML,
      metadata: (try? DIDLLite.parse(metadataXML))?.first,
      relativeTimeText: relativeText,
      relativeTime: SonosTime.duration(from: relativeText)
    )
  }

  func getMediaInfo() async throws -> MediaInfo {
    let response = try await call("GetMediaInfo")
    return MediaInfo(
      numberOfTracks: response.int("NrTracks") ?? 0,
      currentURI: response["CurrentURI"] ?? "",
      currentURIMetadata: response["CurrentURIMetaData"] ?? "",
      nextURI: response["NextURI"] ?? ""
    )
  }

  func setAVTransportURI(_ uri: String, metadata: String = "") async throws {
    try await call("SetAVTransportURI", [
      (name: "CurrentURI", value: uri),
      (name: "CurrentURIMetaData", value: metadata)
    ])
  }

  /// Switches the group to its own queue, where enqueued items play from.
  func useQueue(coordinatorUUID: String) async throws {
    try await setAVTransportURI(AppleMusicURI.queueURI(coordinatorUUID: coordinatorUUID))
  }

  /// `position` is 1-based; 0 appends. Waits the long timeout, as the next one does.
  func addURIToQueue(
    _ item: EnqueueItem,
    position: Int = 0,
    asNext: Bool = false
  ) async throws -> QueueAddResult {
    let response = try await call("AddURIToQueue", [
      (name: "EnqueuedURI", value: item.uri),
      (name: "EnqueuedURIMetaData", value: item.metadata),
      (name: "DesiredFirstTrackNumberEnqueued", value: String(position)),
      (name: "EnqueueAsNext", value: asNext ? "1" : "0")
    ], timeout: .long)
    return queueAddResult(response)
  }

  /// Up to 16 items in one call, the URIs and their metadata space-separated, as the Sonos app
  /// and SoCo send them. A busy player can take a while to answer one, so it waits the long
  /// timeout.
  func addMultipleURIsToQueue(
    _ items: [EnqueueItem],
    container: EnqueueItem? = nil,
    position: Int = 0,
    asNext: Bool = false
  ) async throws -> QueueAddResult {
    let response = try await call("AddMultipleURIsToQueue", [
      (name: "UpdateID", value: "0"),
      (name: "NumberOfURIs", value: String(items.count)),
      (name: "EnqueuedURIs", value: items.map(\.uri).joined(separator: " ")),
      (name: "EnqueuedURIsMetaData", value: items.map(\.metadata).joined(separator: " ")),
      (name: "ContainerURI", value: container?.uri ?? ""),
      (name: "ContainerMetaData", value: container?.metadata ?? ""),
      (name: "DesiredFirstTrackNumberEnqueued", value: String(position)),
      (name: "EnqueueAsNext", value: asNext ? "1" : "0")
    ], timeout: .long)
    return queueAddResult(response)
  }

  private func queueAddResult(_ response: SoapResponse) -> QueueAddResult {
    QueueAddResult(
      firstTrackNumberEnqueued: response.int("FirstTrackNumberEnqueued") ?? 0,
      numberOfTracksAdded: response.int("NumTracksAdded") ?? 0,
      newQueueLength: response.int("NewQueueLength") ?? 0
    )
  }

  /// Clearing a long queue can take a while too, so it waits the long timeout.
  func removeAllTracksFromQueue() async throws {
    try await call("RemoveAllTracksFromQueue", timeout: .long)
  }

  /// Removes the track at `index` (1-based) from the queue.
  func removeTrackFromQueue(index: Int) async throws {
    try await call("RemoveTrackFromQueue", [(name: "ObjectID", value: "Q:0/\(index)"), (name: "UpdateID", value: "0")])
  }

  func play() async throws {
    try await call("Play", [(name: "Speed", value: "1")])
  }

  func pause() async throws {
    try await call("Pause")
  }

  func stop() async throws {
    try await call("Stop")
  }

  func next() async throws {
    try await call("Next")
  }

  func previous() async throws {
    try await call("Previous")
  }

  func seek(toTrack number: Int) async throws {
    try await call("Seek", [(name: "Unit", value: "TRACK_NR"), (name: "Target", value: String(number))])
  }

  func seek(to time: Duration) async throws {
    try await call("Seek", [(name: "Unit", value: "REL_TIME"), (name: "Target", value: SonosTime.text(from: time))])
  }

  /// `NORMAL`, `SHUFFLE`, `SHUFFLE_NOREPEAT`, `REPEAT_ALL`, `REPEAT_ONE`, `SHUFFLE_REPEAT_ONE`.
  func setPlayMode(_ mode: String) async throws {
    try await call("SetPlayMode", [(name: "NewPlayMode", value: mode)])
  }

  func getPlayMode() async throws -> String {
    try await call("GetTransportSettings").require("PlayMode")
  }
}

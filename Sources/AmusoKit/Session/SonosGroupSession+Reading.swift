import Foundation

// MARK: Reading

extension SonosGroupSession {
  /// Everything, from the players: after a command that got no event, and at the start.
  public func refreshAll() async {
    await refreshTransport()
    await refreshVolumes()
  }

  public func refreshTransport() async {
    guard let avTransport else { return }
    do {
      let info = try await avTransport.getTransportInfo()
      let media = try await avTransport.getMediaInfo()
      let position = try await avTransport.getPositionInfo()
      let mode = try await avTransport.getPlayMode()
      var next = transport
      next.state = info.state
      next.source = PlaySource(transportURI: media.currentURI)
      next.numberOfTracks = media.numberOfTracks
      next.currentTrackNumber = position.track
      next.playMode = PlayMode(rawValue: mode) ?? next.playMode
      next.track = NowPlayingTrack(uri: position.uri, metadata: position.metadata, queueIndex: position.track)
      // GetPositionInfo has no stream info; the last event's holds while the track is the same.
      if next.track?.streamInfo == nil, next.track?.uri == transport.track?.uri {
        next.track?.streamInfo = transport.track?.streamInfo
      }
      if next.track?.duration == nil {
        next.track?.duration = position.duration
      }
      next.position = position.relativeTime.map { PositionClock(relativeTime: $0) }
      transport = next
      hasReadState = true
      lastError = nil
    } catch let error as SonosError {
      lastError = error
    } catch {
      lastError = .invalidResponse(error.localizedDescription)
    }
  }

  public func refreshVolumes() async {
    guard let groupRendering else { return }
    var next = volume
    if let value = try? await groupRendering.getGroupVolume() {
      next.groupVolume = value
    }
    if let muted = try? await groupRendering.getGroupMute() {
      next.groupMuted = muted
    }
    for member in group.visibleMembers {
      let rendering = RenderingControlService(client: client, endpoint: member.endpoint)
      if let value = try? await rendering.getVolume() {
        let muted = (try? await rendering.getMute()) ?? false
        next.members[member.uuid] = MemberVolume(volume: value, muted: muted)
      }
    }
    volume = next
  }

  /// The periodic read while the room plays: the transport state first, so that a pause or a stop
  /// whose event never came (the listener's socket gone, a notification lost) is seen within the
  /// interval. Otherwise the app would go on believing the room plays, and on iOS go on playing
  /// its silence and running in the background (`SilentAudioSession`). The whole transport is
  /// read again when the state changed, the position alone otherwise.
  public func resyncWhilePlaying() async {
    guard let avTransport, let info = try? await avTransport.getTransportInfo() else { return }
    if info.state != transport.state {
      await refreshTransport()
    } else {
      await resyncPosition()
    }
  }

  public func resyncPosition() async {
    guard let avTransport, let position = try? await avTransport.getPositionInfo() else { return }
    var next = transport
    next.currentTrackNumber = position.track
    if let track = NowPlayingTrack(uri: position.uri, metadata: position.metadata, queueIndex: position.track) {
      if next.track?.uri != track.uri || next.track == nil {
        next.track = track
      }
      if next.track?.duration == nil {
        next.track?.duration = position.duration
      }
    }
    next.position = position.relativeTime.map { PositionClock(relativeTime: $0) }
    transport = next
  }

  /// The queue, a page at a time.
  public func queue(start: Int = 0, count: Int = 100) async throws -> BrowseResult {
    guard let coordinatorEndpoint else { throw SonosError.notFound("coordinator") }
    return try await ContentDirectoryService(client: client, endpoint: coordinatorEndpoint)
      .browse(objectID: ContentDirectoryService.queueObjectID, start: start, count: count)
  }

  /// Shows `transport` and `volume` as if read from the players, for previews and screenshots: a
  /// session that is never started has no player behind it, and keeps them until changed again.
  public func setPreviewState(transport: TransportSnapshot, volume: VolumeSnapshot) {
    self.transport = transport
    self.volume = volume
    hasReadState = true
  }
}

import Foundation

/// One player's own volume and mute.
nonisolated struct RenderingControlService: Sendable {
  let client: SoapClient
  let endpoint: PlayerEndpoint

  private func call(_ name: String, _ arguments: [(name: String, value: String)] = []) async throws -> SoapResponse {
    try await client.call(
      SoapAction(
        service: .renderingControl,
        name: name,
        arguments: [(name: "InstanceID", value: "0"), (name: "Channel", value: "Master")] + arguments
      ),
      on: endpoint
    )
  }

  func getVolume() async throws -> Int {
    try await call("GetVolume").int("CurrentVolume") ?? 0
  }

  func setVolume(_ volume: Int) async throws {
    _ = try await call("SetVolume", [(name: "DesiredVolume", value: String(max(0, min(100, volume))))])
  }

  func getMute() async throws -> Bool {
    try await call("GetMute")["CurrentMute"] == "1"
  }

  func setMute(_ muted: Bool) async throws {
    _ = try await call("SetMute", [(name: "DesiredMute", value: muted ? "1" : "0")])
  }
}

/// A group's volume and mute, on its coordinator.
nonisolated struct GroupRenderingControlService: Sendable {
  let client: SoapClient
  let endpoint: PlayerEndpoint

  private func call(_ name: String, _ arguments: [(name: String, value: String)] = []) async throws -> SoapResponse {
    try await client.call(
      SoapAction(
        service: .groupRenderingControl,
        name: name,
        arguments: [(name: "InstanceID", value: "0")] + arguments
      ),
      on: endpoint
    )
  }

  func getGroupVolume() async throws -> Int {
    try await call("GetGroupVolume").int("CurrentVolume") ?? 0
  }

  func setGroupVolume(_ volume: Int) async throws {
    _ = try await call("SetGroupVolume", [(name: "DesiredVolume", value: String(max(0, min(100, volume))))])
  }

  func getGroupMute() async throws -> Bool {
    try await call("GetGroupMute")["CurrentMute"] == "1"
  }

  func setGroupMute(_ muted: Bool) async throws {
    _ = try await call("SetGroupMute", [(name: "DesiredMute", value: muted ? "1" : "0")])
  }
}

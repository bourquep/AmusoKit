import Foundation

nonisolated public struct BrowseResult: Sendable, Hashable {
  public var items: [DIDLItem]
  public var numberReturned: Int
  public var totalMatches: Int
  public var updateID: Int
  var rawResult: String
}

/// Browses what a player's media server holds: the queue, favorites, Sonos playlists.
nonisolated struct ContentDirectoryService: Sendable {
  static let queueObjectID = "Q:0"
  static let favoritesObjectID = "FV:2"
  static let sonosPlaylistsObjectID = "SQ:"

  let client: SoapClient
  let endpoint: PlayerEndpoint

  func browse(objectID: String, start: Int = 0, count: Int = 100) async throws -> BrowseResult {
    let response = try await client.call(
      SoapAction(service: .contentDirectory, name: "Browse", arguments: [
        (name: "ObjectID", value: objectID),
        (name: "BrowseFlag", value: "BrowseDirectChildren"),
        (name: "Filter", value: "*"),
        (name: "StartingIndex", value: String(start)),
        (name: "RequestedCount", value: String(count)),
        (name: "SortCriteria", value: "")
      ]),
      on: endpoint
    )
    let raw = response["Result"] ?? ""
    return BrowseResult(
      items: try DIDLLite.parse(raw),
      numberReturned: response.int("NumberReturned") ?? 0,
      totalMatches: response.int("TotalMatches") ?? 0,
      updateID: response.int("UpdateID") ?? 0,
      rawResult: raw
    )
  }

  /// How many tracks the queue holds, from a browse of one.
  func queueLength() async throws -> Int {
    try await browse(objectID: Self.queueObjectID, count: 1).totalMatches
  }
}

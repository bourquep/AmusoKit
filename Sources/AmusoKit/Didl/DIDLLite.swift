import Foundation

/// An item or container described in DIDL-Lite, as players return them and as the app sends them.
nonisolated public struct DIDLItem: Sendable, Hashable {
  public struct Resource: Sendable, Hashable {
    public var uri: String
    public var protocolInfo: String?
    public var durationText: String?
  }

  public var id: String
  public var parentID: String
  public var isContainer: Bool
  public var title: String
  public var creator: String?
  public var album: String?
  public var albumArtURI: String?
  public var upnpClass: String?
  public var resources: [Resource]
  /// The `desc` element's text, such as `SA_RINCON52231_X_#Svc52231-0-Token`.
  public var descriptionToken: String?
  /// `r:resMD`: the metadata a favorite plays with, as escaped DIDL-Lite.
  public var resourceMetadata: String?
  /// `r:description`: the service's name on a favorite, such as "Apple Music".
  public var serviceDescription: String?
  /// `r:streamInfo`: what the player is rendering, on the current track in `AVTransport` events.
  public var streamInfo: String?

  public var primaryURI: String? {
    resources.first?.uri
  }

  /// The Apple Music catalog song id in the item's URI, if it is one.
  public var catalogSongID: String? {
    primaryURI.flatMap { NowPlayingTrack.appleMusicObject(in: $0, kind: "song") }
  }

  /// The Apple Music library track id in the item's URI, if it is one.
  public var libraryTrackID: String? {
    primaryURI.flatMap { NowPlayingTrack.appleMusicObject(in: $0, kind: "librarytrack") }
  }
}

nonisolated enum DIDLLite {
  static let namespaces = "xmlns:dc=\"http://purl.org/dc/elements/1.1/\""
    + " xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\""
    + " xmlns:r=\"urn:schemas-rinconnetworks-com:metadata-1-0/\""
    + " xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\""

  /// Parses a DIDL-Lite document (already unescaped) into its items and containers.
  static func parse(_ xml: String) throws -> [DIDLItem] {
    let trimmed = xml.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed != "NOT_IMPLEMENTED" else { return [] }
    let root = try XMLTree.parse(trimmed)
    return root.children.compactMap { node -> DIDLItem? in
      guard node.name == "item" || node.name == "container" else { return nil }
      let resources = node.children.filter { $0.name == "res" }.map { res in
        DIDLItem.Resource(
          uri: res.text,
          protocolInfo: res.attributes["protocolInfo"],
          durationText: res.attributes["duration"]
        )
      }
      return DIDLItem(
        id: node.attributes["id"] ?? "",
        parentID: node.attributes["parentID"] ?? "",
        isContainer: node.name == "container",
        title: node.childText("title") ?? "",
        creator: node.childText("creator"),
        album: node.childText("album"),
        albumArtURI: node.childText("albumArtURI"),
        upnpClass: node.childText("class"),
        resources: resources,
        descriptionToken: node.child("desc")?.text,
        resourceMetadata: node.childText("resMD"),
        serviceDescription: node.childText("description"),
        streamInfo: node.childText("streamInfo")
      )
    }
  }

  /// What a player needs to enqueue a service item.
  struct ItemSpec: Sendable, Hashable {
    var id: String
    var parentID: String
    var isContainer: Bool
    var title: String
    var upnpClass: String
    /// The service token, such as `SA_RINCON52231_X_#Svc52231-0-Token`.
    var descriptionToken: String

    init(
      id: String,
      parentID: String = "-1",
      isContainer: Bool,
      title: String,
      upnpClass: String,
      descriptionToken: String
    ) {
      self.id = id
      self.parentID = parentID
      self.isContainer = isContainer
      self.title = title
      self.upnpClass = upnpClass
      self.descriptionToken = descriptionToken
    }
  }

  static let descriptionNamespace = "urn:schemas-rinconnetworks-com:metadata-1-0/"

  /// Serializes the metadata a player needs to enqueue a service item.
  static func serialize(_ spec: ItemSpec) -> String {
    let element = spec.isContainer ? "container" : "item"
    return "<DIDL-Lite \(namespaces)>"
      + "<\(element) id=\"\(XMLEscape.escape(spec.id))\""
      + " parentID=\"\(XMLEscape.escape(spec.parentID))\" restricted=\"true\">"
      + "<dc:title>\(XMLEscape.escape(spec.title))</dc:title>"
      + "<upnp:class>\(spec.upnpClass)</upnp:class>"
      + "<desc id=\"cdudn\" nameSpace=\"\(descriptionNamespace)\">"
      + "\(XMLEscape.escape(spec.descriptionToken))</desc>"
      + "</\(element)></DIDL-Lite>"
  }
}

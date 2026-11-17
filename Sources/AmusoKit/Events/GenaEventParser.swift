import Foundation

/// What a `NOTIFY` carried: the service's evented properties, and, for `AVTransport` and
/// `RenderingControl`, the variables of their `LastChange`, which is XML inside XML.
nonisolated struct GenaEvent: Sendable, Hashable {
  /// Property name → text, as the player sent it (unescaped once).
  var properties: [String: String]
  /// Variable name → `val`, from `LastChange`. A channelled variable is keyed `Name/Channel`
  /// (`Volume/Master`).
  var lastChange: [String: String]

  init(properties: [String: String] = [:], lastChange: [String: String] = [:]) {
    self.properties = properties
    self.lastChange = lastChange
  }

  subscript(_ variable: String) -> String? {
    lastChange[variable] ?? properties[variable]
  }
}

nonisolated enum GenaEventParser {
  static func parse(_ body: String) throws -> GenaEvent {
    let root = try XMLTree.parse(body)
    var event = GenaEvent()
    for property in root.all("property") {
      for child in property.children {
        event.properties[child.name] = child.text
      }
    }
    if let lastChange = event.properties["LastChange"], !lastChange.isEmpty {
      event.lastChange = try parseLastChange(lastChange)
    }
    return event
  }

  static func parseLastChange(_ xml: String) throws -> [String: String] {
    let root = try XMLTree.parse(xml)
    var variables: [String: String] = [:]
    let instances = root.all("InstanceID")
    for instance in instances.isEmpty ? [root] : instances {
      for variable in instance.children {
        let value = variable.attributes["val"] ?? variable.text
        if let channel = variable.attributes["channel"] {
          variables["\(variable.name)/\(channel)"] = value
          if channel == "Master" {
            variables[variable.name] = value
          }
        } else {
          variables[variable.name] = value
        }
      }
    }
    return variables
  }
}

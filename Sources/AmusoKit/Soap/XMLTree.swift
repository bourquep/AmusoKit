import Foundation

/// A small XML tree: enough for SOAP envelopes, DIDL-Lite, `ZoneGroupState` and device
/// descriptions. Element names are local names, without their namespace prefix.
nonisolated struct XMLNode: Sendable, Hashable {
  var name: String
  var attributes: [String: String]
  var text: String
  var children: [XMLNode]

  init(name: String, attributes: [String: String] = [:], text: String = "", children: [XMLNode] = []) {
    self.name = name
    self.attributes = attributes
    self.text = text
    self.children = children
  }

  /// The first node with this name, depth first, `self` included.
  func first(_ name: String) -> XMLNode? {
    if self.name == name { return self }
    for child in children {
      if let found = child.first(name) { return found }
    }
    return nil
  }

  /// Every descendant with this name, in document order.
  func all(_ name: String) -> [XMLNode] {
    var result: [XMLNode] = []
    for child in children {
      if child.name == name { result.append(child) }
      result.append(contentsOf: child.all(name))
    }
    return result
  }

  func child(_ name: String) -> XMLNode? {
    children.first { $0.name == name }
  }

  func childText(_ name: String) -> String? {
    child(name)?.text
  }
}

nonisolated struct XMLTreeError: Error, Sendable, CustomStringConvertible {
  var message: String
  var description: String { message }
}

nonisolated enum XMLTree {
  static func parse(_ string: String) throws -> XMLNode {
    try parse(Data(string.utf8))
  }

  static func parse(_ data: Data) throws -> XMLNode {
    let parser = XMLParser(data: data)
    parser.shouldProcessNamespaces = true
    parser.shouldReportNamespacePrefixes = false
    let builder = TreeBuilder()
    parser.delegate = builder
    let succeeded = parser.parse()
    if let error = builder.error, builder.root == nil {
      throw XMLTreeError(message: error)
    }
    guard succeeded || builder.root != nil, let root = builder.root else {
      throw XMLTreeError(message: parser.parserError?.localizedDescription ?? "empty document")
    }
    return root
  }
}

nonisolated private final class TreeBuilder: NSObject, XMLParserDelegate {
  private var stack: [XMLNode] = []
  private(set) var root: XMLNode?
  private(set) var error: String?

  func parser(
    _ parser: XMLParser,
    didStartElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?,
    attributes attributeDict: [String: String] = [:]
  ) {
    stack.append(XMLNode(name: elementName, attributes: attributeDict))
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) {
    guard !stack.isEmpty else { return }
    stack[stack.count - 1].text += string
  }

  func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
    guard !stack.isEmpty else { return }
    stack[stack.count - 1].text += String(decoding: CDATABlock, as: UTF8.self)
  }

  func parser(
    _ parser: XMLParser,
    didEndElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?
  ) {
    guard var node = stack.popLast() else { return }
    node.text = node.text.trimmingCharacters(in: .whitespacesAndNewlines)
    if stack.isEmpty {
      root = node
    } else {
      stack[stack.count - 1].children.append(node)
    }
  }

  func parser(_ parser: XMLParser, parseErrorOccurred parseError: any Error) {
    error = parseError.localizedDescription
  }
}

nonisolated enum XMLEscape {
  /// Escapes text for an element's content or an attribute's value.
  static func escape(_ text: String) -> String {
    text
      .replacing("&", with: "&amp;")
      .replacing("<", with: "&lt;")
      .replacing(">", with: "&gt;")
      .replacing("\"", with: "&quot;")
      .replacing("'", with: "&apos;")
  }
}

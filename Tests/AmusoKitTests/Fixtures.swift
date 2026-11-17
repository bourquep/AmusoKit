import Foundation

/// Player responses captured from real Sonos players, in `Fixtures/`, with the household's
/// identifiers, addresses and room names replaced by made-up ones.
enum Fixtures {
  static func url(_ name: String) -> URL {
    let parts = name.split(separator: ".", maxSplits: 1).map(String.init)
    guard parts.count == 2,
      let url = Bundle.module.url(
        forResource: parts[0], withExtension: parts[1], subdirectory: "Fixtures")
    else {
      fatalError("No fixture named \(name)")
    }
    return url
  }

  static func data(_ name: String) throws -> Data {
    try Data(contentsOf: url(name))
  }

  static func string(_ name: String) throws -> String {
    String(decoding: try data(name), as: UTF8.self)
  }
}

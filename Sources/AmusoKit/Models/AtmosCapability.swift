import Foundation

/// Which Sonos models render Dolby Atmos music, from the model name a player reports.
nonisolated enum AtmosCapability {
  /// Lowercased fragments of the model names that can play Atmos: Era 300, Arc, Arc SL,
  /// Arc Ultra, Beam (Gen 2).
  static let capableFragments = ["era 300", "arc", "beam (gen 2)", "beam gen 2", "beam gen2"]

  static func isCapable(_ description: DeviceDescription?) -> Bool {
    guard let name = description?.modelName?.lowercased() else { return false }
    return capableFragments.contains { name.contains($0) }
  }
}

import Foundation

/// The stream a player is rendering, from the `r:streamInfo` of the current track's metadata in
/// `AVTransport` events, such as `bd:16,sr:48000,c:11,l:0,d:1` for Dolby Atmos. `GetPositionInfo`
/// leaves it out. A stopped player reports every field as 0; a paused one keeps its stream's.
nonisolated public struct StreamInfo: Sendable, Hashable {
  /// `bd`: bits per sample, 0 when unknown.
  public var bitDepth: Int
  /// `sr`: in hertz, 0 when unknown.
  public var sampleRate: Int
  /// `c`: the player's own codec number; 11 is Dolby Digital Plus, Atmos's carrier, and 6 Apple
  /// Music's lossless.
  public var codec: Int
  /// `l`: whether the stream is lossless.
  public var isLossless: Bool
  /// `d`: whether the stream is Dolby Atmos.
  public var isDolbyAtmos: Bool

  public init(
    bitDepth: Int = 0, sampleRate: Int = 0, codec: Int = 0, isLossless: Bool = false, isDolbyAtmos: Bool = false
  ) {
    self.bitDepth = bitDepth
    self.sampleRate = sampleRate
    self.codec = codec
    self.isLossless = isLossless
    self.isDolbyAtmos = isDolbyAtmos
  }

  /// `nil` for an empty or unreadable value; unknown keys are skipped.
  public init?(_ text: String) {
    var fields: [String: Int] = [:]
    for pair in text.split(separator: ",") {
      let parts = pair.split(separator: ":", maxSplits: 1)
      guard parts.count == 2, let value = Int(parts[1].trimmingCharacters(in: .whitespaces)) else { continue }
      fields[parts[0].trimmingCharacters(in: .whitespaces)] = value
    }
    guard !fields.isEmpty else { return nil }
    self.init(
      bitDepth: fields["bd"] ?? 0,
      sampleRate: fields["sr"] ?? 0,
      codec: fields["c"] ?? 0,
      isLossless: fields["l"] == 1,
      isDolbyAtmos: fields["d"] == 1
    )
  }
}

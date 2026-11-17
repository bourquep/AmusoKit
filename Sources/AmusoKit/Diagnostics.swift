/// The package's own names for what it leaves in the unified log and in Instruments: its logs are
/// under the subsystem `app.amuso.AmusoKit` (category `Queue` for the queue fill).
nonisolated enum Diagnostics {
  static let subsystem = "app.amuso.AmusoKit"
}

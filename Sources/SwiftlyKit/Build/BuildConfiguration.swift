/// A debug or release SwiftPM build configuration.
public enum BuildConfiguration: Sendable {
    /// Selects the SwiftPM debug build configuration.
    case debug

    /// Selects the SwiftPM release build configuration.
    case release
}

/// A debug or release SwiftPM build configuration.
public enum BuildConfiguration: Sendable, CaseIterable {

    /// Selects the SwiftPM release build configuration.
    case release

    /// Selects the SwiftPM debug build configuration.
    case debug

}

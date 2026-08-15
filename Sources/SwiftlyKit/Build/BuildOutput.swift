import Foundation

/// The location and lifecycle of a successfully built executable.
public enum BuildOutput: Sendable, Equatable {

    /// Returns an executable from build storage.
    /// A stripped build returns a SwiftlyKit-owned copy and preserves the SwiftPM-produced executable.
    case buildStorage

    /// Atomically copies the executable to a destination, then performs the requested cleanup.
    /// Replacement is opt-in. The parent must exist. Non-retaining cleanup requires output outside build storage.
    case copy(to: URL, replacingExisting: Bool = false, cleanup: BuildCleanup = .retain)

}

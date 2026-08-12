import Foundation

/// The location and lifecycle of a successfully built executable.
public enum BuildOutput: Sendable, Equatable {

    /// Returns an executable from build storage.
    /// A stripped build returns a SwiftlyKit-owned copy and preserves the SwiftPM-produced executable.
    case buildStorage

    /// Atomically copies the executable to a new destination, then performs the requested cleanup.
    /// The destination's parent must exist. Cleanup requires the destination to be outside build storage.
    case copy(to: URL, cleanup: BuildCleanup = .retain)

}

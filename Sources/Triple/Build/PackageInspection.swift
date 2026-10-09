import Foundation

/// A package whose root and dependency manifests were inspected using one bound environment.
public struct PackageInspection: Sendable {

    /// The environment to use for subsequent builds and dependency operations.
    public let environment: LocalBuildEnvironment

    /// The executable products declared by the inspected package.
    public let products: ExecutableProducts

    /// Graph roots reused only while the inspection's owning build operation holds its lease.
    let sourceRoots: [URL]

}

/// Whether package inspection may resolve missing or outdated dependency state.
public enum DependencyResolutionPolicy: Sendable {

    /// Require existing resolved dependencies without accessing the network.
    case requireResolved

    /// Resolve dependencies when inspection requires it, then inspect the complete graph.
    case resolveIfNeeded

}

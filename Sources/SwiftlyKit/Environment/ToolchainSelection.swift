/// A policy for automatic or exact selection of an official stable Swift toolchain.
public enum ToolchainSelection: Sendable, Hashable {
    /// Selects the nearest `.swift-version` preference if the file exists.
    /// Otherwise, selects a compatible installed pair or the newest compatible official release.
    case automatic

    /// Selects the specified official stable release if it supports the package tools version and target architecture.
    case exact(SwiftVersion)
}

/// Selects the Swift toolchain used for an operation.
public enum ToolchainSelection: Sendable, Hashable {
    case automatic
    case exact(SwiftVersion)
}

/// A supported Linux architecture for a build target.
public enum LinuxArchitecture: Sendable, Hashable {
    case arm64
    case x86_64

    /// The Swift SDK selector corresponding to this architecture.
    var swiftSDKSelector: String {
        switch self {
        case .arm64:
            "aarch64-swift-linux-musl"
        case .x86_64:
            "x86_64-swift-linux-musl"
        }
    }

    /// The ELF `e_machine` value corresponding to this architecture.
    var elfMachine: UInt16 {
        switch self {
        case .arm64:
            183
        case .x86_64:
            62
        }
    }
}

/// Selects the platform and architecture for a build.
public enum BuildTarget: Sendable, Hashable {
    case linux(LinuxArchitecture)
}

/// Selects the SwiftPM build configuration.
public enum BuildConfiguration: Sendable, Hashable {
    case debug
    case release
}

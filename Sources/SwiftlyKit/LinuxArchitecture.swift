/// A supported Linux architecture for a build target.
public enum LinuxArchitecture: Sendable, Hashable {
    
    case arm64
    case x86_64
    
}

extension LinuxArchitecture {

    /// The Swift SDK selector corresponding to this architecture.
    var swiftSDKSelector: String {
        switch self {
            case .arm64: "aarch64-swift-linux-musl"
            case .x86_64: "x86_64-swift-linux-musl"
        }
    }

    /// The ELF `e_machine` value corresponding to this architecture.
    var elfMachine: UInt16 {
        switch self {
            case .arm64: 183
            case .x86_64: 62
        }
    }
    
}

/// A supported architecture for a static Linux build target.
public enum LinuxArchitecture: Sendable {
    /// The 64-bit ARM architecture, which Linux identifies as `aarch64`.
    case arm64

    /// The 64-bit x86 architecture.
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

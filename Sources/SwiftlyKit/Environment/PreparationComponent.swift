/// An environment component that preparation can install.
public enum PreparationComponent: Sendable {
    /// The Swiftly command-line tool.
    case swiftly

    /// The selected Swift toolchain.
    case toolchain

    /// The selected Static Linux SDK.
    case staticLinuxSDK
}

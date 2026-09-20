/// An installation or update that environment preparation can perform.
public enum PreparationComponent: Sendable {
    /// The Swiftly command-line tool.
    case swiftly

    /// Permission to check for and apply a Swiftly update before toolchain installation.
    case swiftlyUpdate

    /// The selected Swift toolchain.
    case toolchain

    /// The selected Static Linux SDK.
    case staticLinuxSDK
}

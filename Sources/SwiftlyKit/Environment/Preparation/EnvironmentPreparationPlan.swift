/// Exact, already-authorized mutations. Validation closures bind this to its originating assessment.
struct EnvironmentPreparationPlan: Equatable, Sendable {

    let toolchain: SwiftVersion
    let sdk: StaticLinuxSDKInstallation
    let requiresSwiftly: Bool
    let requiresToolchain: Bool
    let requiresSDK: Bool
    
    init(
        toolchain: SwiftVersion,
        sdk: StaticLinuxSDKInstallation,
        requiresSwiftly: Bool,
        requiresToolchain: Bool = true,
        requiresSDK: Bool = true
    ) {
        self.toolchain = toolchain
        self.sdk = sdk
        self.requiresSwiftly = requiresSwiftly
        self.requiresToolchain = requiresToolchain
        self.requiresSDK = requiresSDK
    }
    
}

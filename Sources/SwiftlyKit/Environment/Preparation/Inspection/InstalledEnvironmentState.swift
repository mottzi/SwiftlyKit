/// Read-only installed state relevant to one exact selected environment.
struct InstalledEnvironmentState: Equatable, Sendable {

    let toolchainVersions: Set<SwiftVersion>
    let sdkIdentifiers: Set<String>

    func contains(toolchain: SwiftVersion, sdkIdentifier: String) -> Bool {
        toolchainVersions.contains(toolchain) && sdkIdentifiers.contains(sdkIdentifier)
    }

}

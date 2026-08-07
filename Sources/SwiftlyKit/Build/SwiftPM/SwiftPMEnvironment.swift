import Foundation

struct SwiftPMEnvironment: Sendable, Equatable {
    
    let swiftlyExecutable: URL
    let toolchainSelector: String
    let sdkID: String
    let sdkArtifactBundle: URL
    let architecture: LinuxArchitecture
    
    init(_ environment: LocalBuildEnvironment) {
        self.swiftlyExecutable = environment.swiftlyExecutableURL
        self.toolchainSelector = environment.swiftVersion.description
        self.sdkID = environment.target.architecture.swiftSDKSelector
        self.sdkArtifactBundle = environment.sdkBundleURL
        self.architecture = environment.target.architecture
    }
    
}

import Foundation

struct SwiftPMEnvironment: Sendable, Equatable {
    
    let swiftlyExecutable: URL
    let toolchainSelector: String
    let sdkID: String
    let sdkArtifactBundle: URL
    let architecture: LinuxArchitecture
    
}

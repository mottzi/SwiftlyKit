import Foundation

struct SwiftPM: Sendable {
    
    let runner: any SubprocessRunning
    let verifier: ELFExecutableVerifier
    let publisher: AtomicOutputPublisher
    let validateEnvironment: @Sendable (LocalBuildEnvironment) throws -> Void
    
    init(
        runner: any SubprocessRunning = LiveSubprocessRunner(),
        verifier: ELFExecutableVerifier = ELFExecutableVerifier(),
        publisher: AtomicOutputPublisher = AtomicOutputPublisher(),
        validateEnvironment: @escaping @Sendable (LocalBuildEnvironment) throws -> Void = {
            try SwiftPM.validate($0)
        }
    ) {
        self.runner = runner
        self.verifier = verifier
        self.publisher = publisher
        self.validateEnvironment = validateEnvironment
    }
    
}

extension SwiftPM {
    
    private static func validate(_ environment: LocalBuildEnvironment) throws {
        let requirements: PackageRequirements
        do {
            requirements = try PackageRequirements.load(at: environment.packageRoot)
        } catch let error as PackageRequirements.LoadingError {
            throw error.swiftlyKitError
        }
        guard requirements.toolsVersion <= environment.swiftVersion else {
            throw SwiftlyKitError.unsupportedToolsVersion(requirements.toolsVersion)
        }
        guard FileManager.default.isExecutableFile(atPath: environment.swiftlyExecutableURL.path) else {
            throw SwiftlyKitError.incompatibleSwiftly
        }
        guard SDKBundleLocator.locate(identifier: environment.staticLinuxSDK.identifier)
                == environment.sdkBundleURL
        else { throw SwiftlyKitError.staticLinuxSDKUnavailable }
    }
    
}

import Foundation
@testable import SwiftlyKit

extension EnvironmentRemover {

    /// Compatibility construction for focused tests; it composes semantic test adapters.
    init(
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        runner: any SubprocessRunning = LiveSubprocessRunner(),
        detectSwiftly: (@Sendable () async throws -> SwiftlyInstallation?)? = nil,
        inspect: @escaping @Sendable (SwiftlyInstallation, SwiftVersion?, Bool) async throws
            -> EnvironmentRemovalInventory = { swiftly, preferredToolchain, includeSDKs in
            try await InstalledEnvironmentInspector().inspectForRemoval(
                swiftly: swiftly,
                toolchain: preferredToolchain,
                includeSDKs: includeSDKs
            )
        }
    ) {
        let detector: @Sendable (EnvironmentStorage) async throws -> SwiftlyInstallation?
        if let detectSwiftly {
            detector = { _ in try await detectSwiftly() }
        } else {
            detector = { storage in try await SwiftlyInstallation.detect(storage: storage) }
        }
        self.init(
            temporaryDirectory: temporaryDirectory,
            runner: runner,
            openSession: { storage in
                guard let swiftly = try await detector(storage) else { return nil }
                return EnvironmentRemovalSession(
                    swiftly: swiftly,
                    inspect: { preferredToolchain, includeSDKs in
                        try await inspect(swiftly, preferredToolchain, includeSDKs)
                    }
                )
            }
        )
    }

}

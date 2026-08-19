import Foundation
@testable import SwiftlyKit

extension SwiftPM {

    /// Test-only construction with package-root source discovery unless a scenario supplies resolved roots.
    init(
        testRunner runner: any SubprocessRunning,
        validateEnvironment: @escaping @Sendable (LocalBuildEnvironment) throws -> Void,
        sourceRoots: @escaping @Sendable (
            LocalBuildEnvironment,
            SwiftPMScratchDirectory
        ) async throws -> [URL] = { environment, _ in [environment.packageRoot] }
    ) {
        self.init(
            runner: runner,
            validateEnvironment: validateEnvironment,
            sourceRoots: sourceRoots
        )
    }

}

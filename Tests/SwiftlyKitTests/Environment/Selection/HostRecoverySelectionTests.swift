import Foundation
import Testing
@testable import SwiftlyKit

@Suite("Host compiler recovery selection")
struct HostRecoverySelectionTests {

    @Test("Automatic advances to a newer assessed release; pins and exact selections remain authoritative")
    func recoveryPreservesIntent() async throws {
        try await withTemporaryDirectory(prefix: "SwiftlyKit-recovery") { directory in
            try Data("// swift-tools-version: 6.0\n".utf8).write(to: directory.appending(path: "Package.swift"))
            let releases = [Self.release("6.4.0"), Self.release("6.3.3")]
            let assessor = testEnvironmentAssessor(releaseCatalog: TestAssessmentReleaseCatalog.current(releases))
            let choices = try await assessor.compatibleEnvironments(directory, for: .linux(.x86_64))
            let failure = SwiftlyKitError.hostCompilationFailed(swiftVersion: SwiftVersion("6.3.3")!, detail: "crash")
            let recovery = try #require(choices.recoveryAssessment(after: failure, for: .automatic))
            #expect(recovery.swiftVersion == SwiftVersion("6.4.0"))
            #expect(recovery.requiresInstallation)
            #expect(choices.recoveryAssessment(after: failure, for: .exact(SwiftVersion("6.3.3")!)) == nil)
            #expect(choices.recoveryAssessment(after: .packageInspectionFailed("syntax error"), for: .automatic) == nil)
            #expect(choices.recoveryAssessment(
                after: .hostCompilationFailed(swiftVersion: SwiftVersion("6.4.0")!, detail: "crash"),
                for: .automatic
            ) == nil)
            try Data("6.3.3\n".utf8).write(to: directory.appending(path: ".swift-version"))
            let pinned = try await assessor.compatibleEnvironments(directory, for: .linux(.x86_64))
            #expect(pinned.recoveryAssessment(after: failure, for: .automatic) == nil)
        }
    }

    private static func release(_ value: String) -> OfficialStableRelease {
        OfficialStableRelease(
            version: SwiftVersion(value)!,
            staticLinuxSDK: StaticLinuxSDK(identifier: "swift-" + value, version: "0.1.0"),
            staticLinuxSDKMetadata: StaticLinuxSDKMetadata(
                downloadURL: URL(string: "https://download.swift.org/sdk.tar.gz")!,
                checksum: String(repeating: "a", count: 64),
                supportedArchitectures: [.x86_64]
            )!
        )
    }

}

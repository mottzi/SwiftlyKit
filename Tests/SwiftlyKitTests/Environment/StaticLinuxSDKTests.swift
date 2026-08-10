import Foundation
import Testing
@testable import SwiftlyKit

@Suite("Static Linux SDK")
struct StaticLinuxSDKTests {

    @Test("Hashable semantics use only the public SDK identity")
    func hashableSemanticsExcludeReleaseMetadata() {

        let first = release(
            downloadURL: URL(string: "https://download.swift.org/first.tar.gz")!,
            checksum: String(repeating: "a", count: 64),
            architectures: [.arm64]
        )
        let second = release(
            downloadURL: URL(string: "https://download.swift.org/second.tar.gz")!,
            checksum: String(repeating: "b", count: 64),
            architectures: [.x86_64]
        )

        #expect(first.staticLinuxSDK == second.staticLinuxSDK)
        #expect(Set([first.staticLinuxSDK, second.staticLinuxSDK]).count == 1)
    }

    private func release(
        downloadURL: URL,
        checksum: String,
        architectures: Set<LinuxArchitecture>
    ) -> OfficialStableRelease {

        OfficialStableRelease(
            version: SwiftVersion(major: 6, minor: 3, patch: 3),
            staticLinuxSDK: StaticLinuxSDK(
                identifier: "swift-6.3.3-RELEASE_static-linux-0.1.0",
                version: "0.1.0"
            ),
            staticLinuxSDKMetadata: StaticLinuxSDKMetadata(
                downloadURL: downloadURL,
                checksum: checksum,
                supportedArchitectures: architectures
            )
        )
    }

}

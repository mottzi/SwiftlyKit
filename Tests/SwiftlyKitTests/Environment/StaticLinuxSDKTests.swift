import Foundation
import Testing
@testable import SwiftlyKit

@Suite("Static Linux SDK")
struct StaticLinuxSDKTests {

    @Test("Metadata construction establishes all download invariants")
    func metadataInvariants() {

        let uppercaseChecksum = String(repeating: "A1", count: 32)

        #expect(metadata(checksum: uppercaseChecksum)?.checksum == uppercaseChecksum.lowercased())
        #expect(metadata(downloadURL: URL(string: "http://download.swift.org/sdk.tar.gz")!) == nil)
        #expect(metadata(checksum: String(repeating: "a", count: 63)) == nil)
        #expect(metadata(checksum: String(repeating: "g", count: 64)) == nil)
        #expect(metadata(checksum: String(repeating: "é", count: 32)) == nil)
        #expect(metadata(architectures: []) == nil)
    }

    private func metadata(
        downloadURL: URL = URL(string: "https://download.swift.org/sdk.tar.gz")!,
        checksum: String = String(repeating: "a", count: 64),
        architectures: Set<LinuxArchitecture> = [.arm64]
    ) -> StaticLinuxSDKMetadata? {

        StaticLinuxSDKMetadata(
            downloadURL: downloadURL,
            checksum: checksum,
            supportedArchitectures: architectures
        )
    }

}

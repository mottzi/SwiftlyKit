import Foundation
import Testing
@testable import SwiftlyKit

@Suite("Swift.org release catalog")
struct SwiftOrgReleaseCatalogTests {
    @Test("Official static SDK metadata produces exact identities and URLs")
    func parsesOfficialMetadata() throws {
        let data = Data("""
            [
              {
                "name": "6.3",
                "tag": "swift-6.3-RELEASE",
                "platforms": [{
                  "platform": "static-sdk",
                  "version": "0.1.0",
                  "checksum": "D2078B69BDEB5C31202C10E9D8A11D6F66F82938B51A4B75F032CCB35C4C286C",
                  "archs": ["x86_64", "arm64"]
                }]
              },
              {
                "name": "6.3.3",
                "tag": "swift-6.3.3-RELEASE",
                "platforms": [{
                  "platform": "static-sdk",
                  "version": "0.1.0",
                  "checksum": "87c3eaf908e67c0e13a84367119e12273cec1d2cd3d81f7d74bb36722d6b607b",
                  "archs": ["x86_64", "arm64"]
                }]
              }
            ]
            """.utf8)

        let releases = try SwiftOrgReleaseCatalog.parse(data)

        #expect(releases.map(\.version) == [swiftVersion("6.3.3"), swiftVersion("6.3")])
        #expect(releases[1].toolchainName == "6.3")
        #expect(releases[1].staticLinuxSDK.identifier == "swift-6.3-RELEASE_static-linux-0.1.0")
        #expect(releases[1].staticLinuxSDK.downloadURL.absoluteString ==
            "https://download.swift.org/swift-6.3-release/static-sdk/swift-6.3-RELEASE/swift-6.3-RELEASE_static-linux-0.1.0.artifactbundle.tar.gz")
        #expect(releases[1].staticLinuxSDK.checksum ==
            "d2078b69bdeb5c31202c10e9d8a11d6f66f82938b51a4b75f032ccb35c4c286c")
        #expect(releases[1].staticLinuxSDK.supportedArchitectures == [.arm64, .x86_64])
    }

    @Test("Malformed and non-SDK releases are excluded without poisoning valid releases")
    func filtersUnusableEntries() throws {
        let checksum = String(repeating: "a", count: 64)
        let data = Data("""
            [
              {"name":"snapshot", "tag":"swift-snapshot", "platforms":[]},
              {"name":"6.2.4", "tag":"wrong-tag", "platforms":[{"platform":"static-sdk","version":"0.1.0","checksum":"\(checksum)","archs":["arm64"]}]},
              {"name":"6.2.3", "tag":"swift-6.2.3-RELEASE", "platforms":[]},
              {"name":"6.2.2", "tag":"swift-6.2.2-RELEASE", "platforms":[{"platform":"static-sdk","version":"0.0.1","checksum":"bad","archs":["arm64"]}]},
              {"name":"6.2.1", "tag":"swift-6.2.1-RELEASE", "platforms":[{"platform":"static-sdk","version":"0.0.1","checksum":"\(checksum)","archs":["future"]}]},
              {"name":"6.2", "tag":"swift-6.2-RELEASE", "platforms":[{"platform":"static-sdk","version":"0.0.1","checksum":"\(checksum)","archs":["arm64"]}]}
            ]
            """.utf8)

        let releases = try SwiftOrgReleaseCatalog.parse(data)
        #expect(releases.map(\.version) == [swiftVersion("6.2")])
    }

    @Test("Invalid JSON is a catalog payload error")
    func rejectsInvalidJSON() {
        #expect(throws: SwiftOrgReleaseCatalog.CatalogError.invalidPayload) {
            try SwiftOrgReleaseCatalog.parse(Data("not json".utf8))
        }
    }

    @Test("Fetching requires a successful HTTP response")
    func validatesHTTPResponse() async {
        let catalog = SwiftOrgReleaseCatalog { url in
            #expect(url == SwiftOrgReleaseCatalog.releasesURL)
            return .init(data: Data("[]".utf8), statusCode: 503)
        }

        await #expect(throws: SwiftOrgReleaseCatalog.CatalogError.unexpectedResponse(statusCode: 503)) {
            try await catalog.stableReleases()
        }
    }
}

private func swiftVersion(_ value: String) -> SwiftVersion {
    SwiftVersion(parsing: value)!
}

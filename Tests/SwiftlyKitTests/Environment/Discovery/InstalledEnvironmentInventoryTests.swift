import Foundation
import Testing
@testable import SwiftlyKit

@Suite("Installed environment inventory")
struct InstalledEnvironmentInventoryTests {

    @Test("Swiftly inventory retains unique stable semantic versions only")
    func parsesStableToolchains() throws {

        let data = Data("""
            {
              "toolchains": [
                {"inUse":false,"isDefault":false,"version":{"name":"xcode","type":"system"}},
                {"inUse":true,"isDefault":true,"version":{"name":"6.2.4","type":"stable"}},
                {"inUse":false,"isDefault":false,"version":{"name":"6.3","type":"stable"}},
                {"inUse":false,"isDefault":false,"version":{"name":"6.2.4","type":"stable"}},
                {"inUse":false,"isDefault":false,"version":{"name":"main-snapshot","type":"snapshot"}}
              ]
            }
            """.utf8)

        let toolchains = try InstalledStableToolchain.parseSwiftlyList(data)
        #expect(toolchains.map(\.version) == [inventoryVersion("6.3"), inventoryVersion("6.2.4")])
    }

    @Test("Malformed Swiftly JSON is rejected")
    func rejectsMalformedToolchainInventory() {
        #expect(throws: InventoryError.invalidSwiftlyPayload) {
            try InstalledStableToolchain.parseSwiftlyList(Data("{}".utf8))
        }
    }

    @Test("SDK inventory is scoped to the toolchain used to list it")
    func parsesStaticSDKs() {

        let toolchain = inventoryVersion("6.3.3")
        let sdks = InstalledStaticLinuxSDK.parseList(
            """
            swift-6.3.3-RELEASE_static-linux-0.1.0
            custom-sdk
            swift-6.3.3-RELEASE_static-linux-0.1.0
            warning: static-linux-sdk unavailable
            """,
            toolchainVersion: toolchain
        )

        #expect(sdks == [InstalledStaticLinuxSDK(
            toolchainVersion: toolchain,
            identifier: "swift-6.3.3-RELEASE_static-linux-0.1.0"
        )])
    }

}

private func inventoryVersion(_ value: String) -> SwiftVersion {
    SwiftVersion(parsing: value)!
}

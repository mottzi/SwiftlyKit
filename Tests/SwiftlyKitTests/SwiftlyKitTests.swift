import Foundation
import Testing
@testable import SwiftlyKit

@Suite("SwiftlyKit value models")
struct ValueModelTests {

    @Test("Swift versions describe and compare numerically")
    func swiftVersionDescriptionAndOrdering() {

        let patch = SwiftVersion(major: 6, minor: 1, patch: 1)
        let minor = SwiftVersion(major: 6, minor: 2, patch: 0)
        let major = SwiftVersion(major: 7, minor: 0, patch: 0)

        #expect(patch.description == "6.1.1")
        #expect(patch < minor)
        #expect(minor < major)
        #expect(SwiftVersion(major: 6, minor: 2, patch: 0) == minor)
        #expect(SwiftVersion(major: 6, minor: 2, patch: 1) > minor)
    }

    @Test("Linux architectures map to their SDK selectors and ELF values")
    func linuxArchitectureMappings() {

        #expect(LinuxArchitecture.arm64.swiftSDKSelector == "aarch64-swift-linux-musl")
        #expect(LinuxArchitecture.x86_64.swiftSDKSelector == "x86_64-swift-linux-musl")
        #expect(LinuxArchitecture.arm64.elfMachine == 183)
        #expect(LinuxArchitecture.x86_64.elfMachine == 62)
    }

    @Test("Build requests provide the documented defaults")
    func buildRequestDefaults() {

        let request = BuildRequest(
            ExecutableProduct(name: "Server")
        )

        #expect(request.configuration == .debug)
        #expect(request.scratchDirectory == nil)
        #expect(request.output == nil)
        #expect(request.strip == false)
        #expect(request.environment.isEmpty)
    }

}

import Testing
@testable import SwiftlyKit

@Suite("Linux architecture")
struct LinuxArchitectureTests {

    @Test("Architectures map to their SDK selectors and ELF values")
    func mappings() {

        #expect(LinuxArchitecture.arm64.swiftSDKSelector == "aarch64-swift-linux-musl")
        #expect(LinuxArchitecture.x86_64.swiftSDKSelector == "x86_64-swift-linux-musl")
        #expect(LinuxArchitecture.arm64.elfMachine == 183)
        #expect(LinuxArchitecture.x86_64.elfMachine == 62)
    }

}

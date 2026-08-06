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

    @Test("Toolchain selection supports automatic and exact versions")
    func toolchainSelection() {
        let version = SwiftVersion(major: 6, minor: 2, patch: 0)

        #expect(ToolchainSelection.automatic == .automatic)
        #expect(ToolchainSelection.exact(version) == .exact(version))
        #expect(ToolchainSelection.exact(version) != .automatic)
    }

    @Test("Linux architectures map to their SDK selectors and ELF values")
    func linuxArchitectureMappings() {
        #expect(LinuxArchitecture.arm64.swiftSDKSelector == "aarch64-swift-linux-musl")
        #expect(LinuxArchitecture.x86_64.swiftSDKSelector == "x86_64-swift-linux-musl")
        #expect(LinuxArchitecture.arm64.elfMachine == 183)
        #expect(LinuxArchitecture.x86_64.elfMachine == 62)
    }

    @Test("Executable products use name identity")
    func executableProductIdentity() {
        let server = ExecutableProduct(name: "Server")
        let sameServer = ExecutableProduct(name: "Server")
        let client = ExecutableProduct(name: "Client")

        #expect(server.name == "Server")
        #expect(server == sameServer)
        #expect(server != client)
    }

    @Test("Build requests preserve supplied values")
    func buildRequestPreservesValues() {
        let packageRoot = URL(filePath: "/tmp/example")
        let scratchDirectory = URL(filePath: "/tmp/example/.build")
        let output = URL(filePath: "/tmp/example/server")
        let request = BuildRequest(
            ExecutableProduct(name: "Server"),
            in: packageRoot,
            for: .linux(.arm64),
            configuration: .release,
            scratchDirectory: scratchDirectory,
            output: output,
            strip: true,
            environment: ["SWIFT_VERSION": "6.2"]
        )

        #expect(request.product.name == "Server")
        #expect(request.packageRoot == packageRoot)
        #expect(request.target == .linux(.arm64))
        #expect(request.configuration == .release)
        #expect(request.scratchDirectory == scratchDirectory)
        #expect(request.output == output)
        #expect(request.strip)
        #expect(request.environment == ["SWIFT_VERSION": "6.2"])
    }

    @Test("Build requests provide the documented defaults")
    func buildRequestDefaults() {
        let request = BuildRequest(
            ExecutableProduct(name: "Server"),
            in: URL(filePath: "/tmp/example"),
            for: .linux(.x86_64)
        )

        #expect(request.configuration == .debug)
        #expect(request.scratchDirectory == nil)
        #expect(request.output == nil)
        #expect(request.strip == false)
        #expect(request.environment.isEmpty)
    }
}

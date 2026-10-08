import Foundation
import Testing
@testable import SwiftlyKit

@Suite("Live host manifest cache")
struct LiveHostManifestCacheTests {

    @Test(
        "Cached dependency manifests preserve SDK recovery and invalidate changed manifests",
        .enabled(
            if: ProcessInfo.processInfo.environment["SWIFTLYKIT_TEST_HOST_CACHE"] == "1",
            "Requires installed Swift 6.3.3, its Linux SDK, macOS SDK 27, and SDK 26.5."
        )
    )
    func recoveryAndInvalidation() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-live-cache") { root in
            let dependency = root.appending(path: "Dependency")
            let tool = root.appending(path: "Sources/Tool")
            let core = dependency.appending(path: "Sources/Core")
            try FileManager.default.createDirectory(at: tool, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: core, withIntermediateDirectories: true)
            try Data("print(\"test\")".utf8).write(to: tool.appending(path: "main.swift"))
            try Data("public enum Core {}".utf8).write(to: core.appending(path: "Core.swift"))
            try Data(Self.rootManifest.utf8).write(to: root.appending(path: "Package.swift"))
            let manifest = dependency.appending(path: "Package.swift")
            try Data(Self.dependencyManifest.utf8).write(to: manifest)

            let kit = SwiftlyKit()
            let version = SwiftVersion(major: 6, minor: 3, patch: 3)
            let assessment = try await kit.assess(root, for: .linux(.x86_64), toolchain: .exact(version))
            try #require(!assessment.requiresInstallation)
            let environment = try await kit.prepare(assessment)
            try #require(environment.hostSDKVersion == "27.0")

            for _ in 1...2 {
                let inspection = try await kit.inspectPackage(using: environment, dependencies: .resolveIfNeeded)
                #expect(inspection.environment.swiftVersion == version)
                #expect(inspection.environment.hostSDKVersion == "26.5")
                #expect(inspection.products.map(\.name) == ["Tool"])
            }

            try Data((Self.dependencyManifest + "\nlet changedManifest = missingDeclaration\n").utf8).write(to: manifest)
            do {
                _ = try await kit.inspectPackage(using: environment, dependencies: .resolveIfNeeded)
                Issue.record("A cached successful dependency manifest must not hide a new compiler error.")
            } catch let error as SwiftlyKitError {
                #expect(error.localizedDescription.contains("missingDeclaration"))
            }
        }
    }

    private static let rootManifest = """
    // swift-tools-version: 6.0
    import PackageDescription
    let package = Package(name: "Tool", products: [.executable(name: "Tool", targets: ["Tool"])],
        dependencies: [.package(path: "Dependency")],
        targets: [.executableTarget(name: "Tool", dependencies: [.product(name: "Core", package: "Dependency")])])
    """

    private static let dependencyManifest = """
    // swift-tools-version: 6.0
    import class Foundation.ProcessInfo
    import PackageDescription
    let name = ProcessInfo.processInfo.environment["SWIFTLYKIT_CACHE_TEST_NAME"] ?? "Dependency"
    let package = Package(name: name, products: [.library(name: "Core", targets: ["Core"])],
        targets: [.target(name: "Core")])
    """

}

import Foundation
import Testing
@testable import Triple

@Suite("Host manifest cache")
struct HostManifestCacheTests {

    @Test("Unchanged host contexts reuse caches; SDK and compiler replacement change the identity")
    func contextChanges() throws {

        try withTemporaryDirectory(prefix: "Triple-manifest-cache") { directory in
            let developer = directory.appending(path: "Developer")
            let sdk = developer.appending(path: "SDKs/MacOSX.sdk")
            try FileManager.default.createDirectory(at: sdk, withIntermediateDirectories: true)
            let settings = sdk.appending(path: "SDKSettings.json")
            try Data(#"{"Version":"27.0"}"#.utf8).write(to: settings)
            let storage = directory.appending(path: "Environment")
            let toolchain = storage.appending(path: "toolchains/swift-6.4.0-RELEASE.xctoolchain")
            let files = ["usr/bin/swift-frontend", "usr/bin/swift-driver", "usr/bin/swift-package",
                         "usr/lib/swift/pm/ManifestAPI/libPackageDescription.dylib"]
            for file in files {
                let url = toolchain.appending(path: file)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("compiler".utf8).write(to: url)
            }

            let environment = try Self.environment(in: directory, storage: storage, sdk: sdk, developer: developer)
            let first = SwiftPM.command(environment, swiftArguments: ["package", "dump-package"])
            let second = SwiftPM.command(environment, swiftArguments: ["package", "show-dependencies"])
            let identity = try #require(first.environment?[HostManifestCache.environmentKey])
            #expect(second.environment?[HostManifestCache.environmentKey] == identity)
            #expect(first.arguments.contains("shared"))
            #expect(!first.arguments.contains("--cache-path"))
            let limited = try Self.environment(
                in: directory,
                storage: storage,
                sdk: sdk,
                developer: developer,
                processEnvironment: ["SWIFTPM_MAX_CONCURRENT_OPERATIONS": "2"]
            )
            let limitedCommand = SwiftPM.command(limited, swiftArguments: ["package", "show-dependencies"])
            #expect(limitedCommand.environment?["SWIFTPM_MAX_CONCURRENT_OPERATIONS"] == "2")

            try Data(#"{"Version":"27.0","Revision":2}"#.utf8).write(to: settings)
            let replacedSDK = try Self.environment(in: directory, storage: storage, sdk: sdk, developer: developer)
            let changedSDK = SwiftPM.command(replacedSDK, swiftArguments: ["package", "dump-package"])
            #expect(changedSDK.environment?[HostManifestCache.environmentKey] != identity)

            try Data("replacement compiler".utf8).write(to: toolchain.appending(path: "usr/bin/swift-frontend"))
            let changedCompiler = SwiftPM.command(environment, swiftArguments: ["package", "dump-package"])
            #expect(changedCompiler.environment?[HostManifestCache.environmentKey] != identity)

            try FileManager.default.removeItem(at: toolchain.appending(path: "usr/bin/swift-package"))
            let unavailable = SwiftPM.command(environment, swiftArguments: ["package", "dump-package"])
            #expect(unavailable.environment?[HostManifestCache.environmentKey] == nil)
            #expect(unavailable.arguments.contains("none"))
        }
    }

    private static func environment(
        in directory: URL,
        storage: URL,
        sdk: URL,
        developer: URL,
        processEnvironment: [String: String] = [:]
    ) throws -> LocalBuildEnvironment {
        LocalBuildEnvironment(
            swiftVersion: SwiftVersion(major: 6, minor: 4, patch: 0),
            staticLinuxSDK: StaticLinuxSDK(identifier: "test", version: "test"),
            packageRoot: directory,
            swiftly: SwiftlyInstallation(executableURL: storage.appending(path: "bin/swiftly")),
            sdkBundleURL: directory.appending(path: "linux.artifactbundle"),
            target: .linux(.x86_64),
            swiftPMEnvironment: SwiftPMEnvironment.inherited.snapshot(inheriting: processEnvironment),
            environmentStorage: .directory(storage),
            hostSDK: try HostSDK(directory: sdk, developerDirectory: developer)
        )
    }

}

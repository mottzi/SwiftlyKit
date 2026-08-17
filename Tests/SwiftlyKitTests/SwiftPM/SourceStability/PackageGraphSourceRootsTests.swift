import Foundation
import Testing
@testable import SwiftlyKit

@Suite("Package graph source roots")
struct PackageGraphSourceRootsTests {

    @Test("Resolved local and checkout dependencies become observed source roots")
    func resolvedGraph() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-PackageGraph") { directory in
            let localDependency = directory.appending(path: "../LocalDependency").standardized
            let checkout = directory.appending(path: ".build/checkouts/RemoteDependency")
            let graph = """
            {
              "path": "\(directory.path(percentEncoded: false))",
              "dependencies": [
                {
                  "path": "\(localDependency.path(percentEncoded: false))",
                  "dependencies": []
                },
                {
                  "path": "\(checkout.path(percentEncoded: false))",
                  "dependencies": []
                }
              ]
            }
            """
            let runner = RecordingSubprocessRunner(results: [.success(output: graph)])
            let values = try SwiftPMEnvironment(["GRAPH_VALUE": .plain("enabled")])
            let sharedRoot = directory.deletingLastPathComponent()
                .appending(path: "SwiftlyKit-graph-shared-\(UUID().uuidString)", directoryHint: .isDirectory)
            let sharedStorage = SwiftPMSharedStorage(
                cacheDirectory: sharedRoot.appending(path: "cache", directoryHint: .isDirectory),
                configurationDirectory: sharedRoot.appending(path: "configuration", directoryHint: .isDirectory),
                securityDirectory: sharedRoot.appending(path: "security", directoryHint: .isDirectory)
            )
            defer { try? FileManager.default.removeItem(at: sharedRoot) }
            let environment = packageGraphEnvironment(
                in: directory,
                swiftPMEnvironment: values.snapshot(inheriting: [:]),
                swiftPMTraits: try SwiftPMTraits(["GraphFeature"], includingDefaults: true),
                swiftPMSharedStorage: sharedStorage
            )
            let scratch = try SwiftPMScratchDirectory(
                storage: .directory(directory.appending(path: "scratch")),
                packageRoot: directory
            )

            let roots = try await SwiftPM.packageGraphSourceRoots(
                using: environment,
                scratchDirectory: scratch,
                runner: runner
            )

            #expect(Set(roots.map(\.pathComponents)) == Set([directory, localDependency, checkout].map(\.pathComponents)))
            let command = try #require(await runner.commands.first)
            #expect(command.arguments.prefix(3) == ["run", "swift", "package"])
            #expect(command.arguments.contains("--disable-automatic-resolution"))
            #expect(try argument(after: "--traits", in: command.arguments) == "GraphFeature,default")
            let subcommandIndex = try #require(command.arguments.firstIndex(of: "show-dependencies"))
            let traitsIndex = try #require(command.arguments.firstIndex(of: "--traits"))
            #expect(traitsIndex < subcommandIndex)
            #expect(command.arguments.contains("show-dependencies"))
            #expect(command.arguments.contains("--format"))
            #expect(command.arguments.contains("json"))
            #expect(command.arguments.contains(scratch.url.path(percentEncoded: false)))
            #expect(command.environment?["GRAPH_VALUE"] == "enabled")

            let packageIndex = try #require(command.arguments.firstIndex(of: "package"))
            for (option, path) in [
                ("--cache-path", sharedRoot.appending(path: "cache")),
                ("--config-path", sharedRoot.appending(path: "configuration")),
                ("--security-path", sharedRoot.appending(path: "security"))
            ] {
                let optionIndex = try #require(command.arguments.firstIndex(of: option))
                #expect(packageIndex < optionIndex)
                #expect(optionIndex < subcommandIndex)
                #expect(normalizedPath(try argument(after: option, in: command.arguments))
                    == normalizedPath(path.path(percentEncoded: false)))
            }
        }
    }

}

private func packageGraphEnvironment(
    in directory: URL,
    swiftPMEnvironment: SwiftPMEnvironment.Snapshot = SwiftPMEnvironment.inherited.snapshot(),
    swiftPMTraits: SwiftPMTraits = .packageDefaults,
    swiftPMSharedStorage: SwiftPMSharedStorage = .standard
) -> LocalBuildEnvironment {
    LocalBuildEnvironment(
        swiftVersion: SwiftVersion(major: 6, minor: 2, patch: 1),
        staticLinuxSDK: StaticLinuxSDK(
            identifier: "sdk",
            version: "1.0.0"
        ),
        packageRoot: directory,
        swiftly: SwiftlyInstallation(executableURL: URL(filePath: "/swiftly")),
        sdkBundleURL: directory.appending(path: "sdk.artifactbundle"),
        target: .linux(.arm64),
        swiftPMEnvironment: swiftPMEnvironment,
        swiftPMTraits: swiftPMTraits,
        swiftPMSharedStorage: swiftPMSharedStorage
    )
}

private func argument(after option: String, in arguments: [String]) throws -> String {
    let optionIndex = try #require(arguments.firstIndex(of: option))
    return try #require(arguments.dropFirst(optionIndex + 1).first)
}

private func normalizedPath(_ path: String) -> String {
    let normalized = URL(filePath: path).standardizedFileURL.path(percentEncoded: false)
    guard normalized != "/" else { return normalized }
    return normalized.hasSuffix("/") ? String(normalized.dropLast()) : normalized
}

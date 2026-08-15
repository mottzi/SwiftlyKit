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
            let environment = packageGraphEnvironment(
                in: directory,
                swiftPMEnvironment: values.snapshot(inheriting: [:]),
                swiftPMTraits: try SwiftPMTraits(["GraphFeature"], includingDefaults: true)
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
            #expect(command.arguments.prefix(4) == [
                "run", "swift", "package", "--disable-automatic-resolution"
            ])
            #expect(try argument(after: "--traits", in: command.arguments) == "GraphFeature,default")
            let subcommandIndex = try #require(command.arguments.firstIndex(of: "show-dependencies"))
            let traitsIndex = try #require(command.arguments.firstIndex(of: "--traits"))
            #expect(traitsIndex < subcommandIndex)
            #expect(command.arguments.contains("show-dependencies"))
            #expect(command.arguments.contains("--format"))
            #expect(command.arguments.contains("json"))
            #expect(command.arguments.contains(scratch.url.path(percentEncoded: false)))
            #expect(command.environment?["GRAPH_VALUE"] == "enabled")
        }
    }

}

private func packageGraphEnvironment(
    in directory: URL,
    swiftPMEnvironment: SwiftPMEnvironment.Snapshot = SwiftPMEnvironment.inherited.snapshot(),
    swiftPMTraits: SwiftPMTraits = .packageDefaults
) -> LocalBuildEnvironment {
    LocalBuildEnvironment(
        swiftVersion: SwiftVersion(major: 6, minor: 2, patch: 1),
        staticLinuxSDK: StaticLinuxSDK(identifier: "sdk", version: "1.0.0"),
        packageRoot: directory,
        swiftly: SwiftlyInstallation(executableURL: URL(filePath: "/swiftly")),
        sdkBundleURL: directory.appending(path: "sdk.artifactbundle"),
        target: .linux(.arm64),
        swiftPMEnvironment: swiftPMEnvironment,
        swiftPMTraits: swiftPMTraits
    )
}

private func argument(after option: String, in arguments: [String]) throws -> String {
    let optionIndex = try #require(arguments.firstIndex(of: option))
    return try #require(arguments.dropFirst(optionIndex + 1).first)
}

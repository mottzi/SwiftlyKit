import Foundation
import Testing
@testable import SwiftlyKit

@Suite("SwiftPM trait fixtures")
struct SwiftPMTraitsFixtureTests {

    @Test("Inspection, graph discovery, resolution, and build use one trait configuration")
    func conditionalTraitWorkflow() async throws {

        try await withFixtureCopy { packageRoot in
            let traits = try SwiftPMTraits(["SelectedFeature"], includingDefaults: true)
            let packageArguments = ["swift", "package"] + traits.arguments
            let runner = LiveSubprocessRunner()
            let dump = try await runner.run(
                command(packageArguments + ["dump-package"], in: packageRoot),
                onOutput: nil
            )
            let graph = try await runner.run(
                command(packageArguments + ["show-dependencies", "--format", "json"], in: packageRoot),
                onOutput: nil
            )
            let resolution = try await runner.run(
                command(packageArguments + ["resolve"], in: packageRoot),
                onOutput: nil
            )
            let scratch = packageRoot.appending(path: "scratch")
            let build = try await runner.run(
                command(
                    ["swift", "build"] + traits.arguments + [
                        "--product", "Tool",
                        "--scratch-path", scratch.path(percentEncoded: false)
                    ],
                    in: packageRoot
                ),
                onOutput: nil
            )

            #expect(dump.succeeded)
            #expect(dump.standardOutput.contains("SelectedFeature"))
            #expect(graph.succeeded)
            #expect(try graphTraits(graph.standardOutput) == ["DefaultFeature", "SelectedFeature"])
            #expect(resolution.succeeded)
            #expect(build.succeeded)

            let executable = scratch.appending(path: "debug/Tool")
            let run = try await runner.run(
                SubprocessCommand(
                    executableURL: executable,
                    arguments: [],
                    workingDirectory: packageRoot
                ),
                onOutput: nil
            )
            #expect(run.succeeded)
            #expect(run.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) == "selected+default")
        }
    }

}

extension SwiftPMTraitsFixtureTests {

    private func command(_ arguments: [String], in packageRoot: URL) -> SubprocessCommand {
        SubprocessCommand(
            executableURL: URL(filePath: "/usr/bin/env"),
            arguments: arguments,
            workingDirectory: packageRoot
        )
    }

    private func graphTraits(_ output: String) throws -> Set<String> {

        let data = try #require(output.data(using: .utf8))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return Set(try #require(object["traits"] as? [String]))
    }

    private func withFixtureCopy(_ operation: (URL) async throws -> Void) async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-Traits") { directory in
            let resourceRoot = try #require(Bundle.module.resourceURL)
            let source = resourceRoot.appending(path: "TraitConditionalPackage")
            let packageRoot = directory.appending(path: "Package")
            try FileManager.default.copyItem(at: source, to: packageRoot)
            try await operation(packageRoot)
        }
    }

}

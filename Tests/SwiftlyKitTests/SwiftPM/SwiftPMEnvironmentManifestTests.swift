import Foundation
import Testing
@testable import SwiftlyKit

@Suite("SwiftPM environment manifest fixtures")
struct SwiftPMEnvironmentManifestTests {

    @Test("Product discovery and build use the same conditional manifest value")
    func conditionalManifest() async throws {

        try await withFixtureCopy { packageRoot in
            let values = try SwiftPMEnvironment(["PACKAGE_FLAVOR": .plain("production")])
            let snapshot = values.snapshot()
            let runner = LiveSubprocessRunner()
            let dump = try await runner.run(
                command(
                    ["swift", "package", "dump-package"],
                    in: packageRoot,
                    snapshot: snapshot
                ),
                onOutput: nil
            )
            let scratch = packageRoot.appending(path: "scratch")
            let build = try await runner.run(
                command(
                    [
                        "swift", "build", "--product", "ProductionTool",
                        "--scratch-path", scratch.path(percentEncoded: false)
                    ],
                    in: packageRoot,
                    snapshot: snapshot
                ),
                onOutput: nil
            )

            #expect(dump.succeeded)
            #expect(dump.standardOutput.contains("ProductionTool"))
            #expect(build.succeeded)
        }
    }

    @Test("A failing manifest cannot publish a sensitive value")
    func failingManifestRedaction() async throws {

        try await withFixtureCopy { packageRoot in
            let secret = "fixture-private-value"
            let values = try SwiftPMEnvironment(["FAILURE_SECRET": .sensitive(secret)])
            let snapshot = values.snapshot()
            let recorder = ManifestOutputRecorder()
            let result = try await LiveSubprocessRunner().run(
                command(
                    ["swift", "package", "dump-package"],
                    in: packageRoot,
                    snapshot: snapshot
                ),
                onOutput: { _, text in await recorder.record(text) }
            )

            #expect(!result.succeeded)
            #expect(!result.standardOutput.contains(secret))
            #expect(!result.standardError.contains(secret))
            #expect(result.standardOutput.contains(SensitiveValueRedactor.placeholder)
                || result.standardError.contains(SensitiveValueRedactor.placeholder))
            #expect(!(await recorder.output).contains(secret))

            let diagnostic = SwiftPM.boundedDiagnostic(result)
            let error = SwiftPMError.commandFailed(
                operation: .inspectingPackage,
                diagnostic: diagnostic
            ).swiftlyKitError
            #expect(!error.localizedDescription.contains(secret))
            #expect(error.localizedDescription.contains(SensitiveValueRedactor.placeholder))
        }
    }

}

extension SwiftPMEnvironmentManifestTests {

    private func command(
        _ arguments: [String],
        in packageRoot: URL,
        snapshot: SwiftPMEnvironment.Snapshot
    ) -> SubprocessCommand {

        SubprocessCommand(
            executableURL: URL(filePath: "/usr/bin/env"),
            arguments: arguments,
            workingDirectory: packageRoot,
            environment: snapshot.values,
            sensitiveEnvironmentKeys: snapshot.sensitiveNames
        )
    }

    private func withFixtureCopy(_ operation: (URL) async throws -> Void) async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-EnvironmentManifest") { directory in
            let resourceRoot = try #require(Bundle.module.resourceURL)
            let source = resourceRoot.appending(path: "EnvironmentConditionalPackage")
            let packageRoot = directory.appending(path: "Package")
            try FileManager.default.copyItem(at: source, to: packageRoot)
            try await operation(packageRoot)
        }
    }

}

private actor ManifestOutputRecorder {

    private(set) var output = ""

    func record(_ text: String) {
        output.append(text)
    }

}

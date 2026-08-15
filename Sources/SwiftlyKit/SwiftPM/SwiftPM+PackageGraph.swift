import Foundation

extension SwiftPM {

    /// Returns every source root in the resolved package graph without changing dependency state.
    static func packageGraphSourceRoots(
        using environment: LocalBuildEnvironment,
        scratchDirectory: SwiftPMScratchDirectory,
        runner: any SubprocessRunning
    ) async throws -> [URL] {

        var arguments = [
            "package",
            "--disable-automatic-resolution"
        ]
        arguments += environment.swiftPMTraits.arguments
        if scratchDirectory.isExplicit {
            arguments += [
                "--scratch-path",
                scratchDirectory.url.path(percentEncoded: false)
            ]
        }
        arguments += [
            "show-dependencies",
            "--format", "json"
        ]

        let result = try await runner.run(
            Self.command(environment, swiftArguments: arguments),
            onOutput: nil
        )

        guard result.succeeded else {
            let diagnostic = Self.boundedDiagnostic(result)
            if Self.indicatesRequiredResolution(diagnostic) { throw SwiftPMError.dependencyResolutionRequired }
            throw SwiftPMError.commandFailed(operation: .inspectingPackage, diagnostic: diagnostic)
        }

        guard let data = result.standardOutput.data(using: .utf8),
              let roots = try? PackageGraphSourceRoots(data: data).urls,
              !roots.isEmpty
        else { throw SwiftPMError.malformedPackageDescription }

        return roots
    }

}

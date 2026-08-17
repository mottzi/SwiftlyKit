import Foundation

extension SwiftPM {

    /// Returns one bounded diagnostic from a subprocess result.
    static func boundedDiagnostic(_ result: SubprocessResult) -> String {
        String((result.standardError + "\n" + result.standardOutput).suffix(16_384))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func indicatesRequiredResolution(_ diagnostic: String) -> Bool {

        let lowercased = diagnostic.lowercased()

        return lowercased.contains("package.resolved")
            || lowercased.contains("automatic resolution is disabled")
            || lowercased.contains("dependencies could not be resolved")
    }

}

extension SwiftPM {

    /// Creates a SwiftPM command with the snapshot bound to the prepared environment.
    static func command(
        _ environment: LocalBuildEnvironment,
        swiftArguments: [String]
    ) -> SubprocessCommand {

        var swiftArguments = swiftArguments
        if !swiftArguments.isEmpty {
            swiftArguments.insert(
                contentsOf: environment.swiftPMSharedStorage.commandArguments,
                at: 1
            )
        }

        return Self.command(
            environment,
            tool: "swift",
            toolArguments: swiftArguments,
            processEnvironment: environment.swiftPMEnvironment.values,
            sensitiveEnvironmentKeys: environment.swiftPMEnvironment.sensitiveNames
        )
    }

    /// Creates a selected non-SwiftPM tool command without caller environment values.
    static func toolCommand(
        _ environment: LocalBuildEnvironment,
        tool: String,
        toolArguments: [String]
    ) -> SubprocessCommand {

        Self.command(
            environment,
            tool: tool,
            toolArguments: toolArguments,
            processEnvironment: environment.swiftPMEnvironment.toolValues,
            sensitiveEnvironmentKeys: []
        )
    }

}

extension SwiftPM {

    private static func command(
        _ environment: LocalBuildEnvironment,
        tool: String,
        toolArguments: [String],
        processEnvironment: [String: String],
        sensitiveEnvironmentKeys: Set<String>
    ) -> SubprocessCommand {

        var processEnvironment = processEnvironment
        processEnvironment["SWIFTLY_BIN_DIR"] = environment.swiftly.executableURL
            .deletingLastPathComponent()
            .path(percentEncoded: false)

        return environment.swiftly.command(
            tool: tool,
            toolchain: environment.swiftVersion,
            arguments: toolArguments,
            workingDirectory: environment.packageRoot,
            environment: processEnvironment,
            sensitiveEnvironmentKeys: sensitiveEnvironmentKeys
        )
    }

}

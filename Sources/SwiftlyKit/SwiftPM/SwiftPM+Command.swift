import Foundation

extension SwiftPM {

    /// Returns one bounded diagnostic from a subprocess result.
    static func boundedDiagnostic(_ result: SubprocessResult) -> String {
        String((result.standardError + "\n" + result.standardOutput).suffix(16_384))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

}

extension SwiftPM {

    /// Creates a Swift command for the prepared toolchain and protected environment.
    static func command(
        _ environment: LocalBuildEnvironment,
        swiftArguments: [String],
        additions: [String: String] = [:]
    ) -> SubprocessCommand {

        Self.command(
            environment,
            tool: "swift",
            toolArguments: swiftArguments,
            additions: additions
        )
    }

    /// Creates a selected-tool command for the prepared toolchain and protected environment.
    static func command(
        _ environment: LocalBuildEnvironment,
        tool: String,
        toolArguments: [String],
        additions: [String: String]
    ) -> SubprocessCommand {

        let inheritedEnvironment = ProcessInfo.processInfo.environment
        var processEnvironment = inheritedEnvironment
        processEnvironment.merge(additions) { _, requested in requested }

        let protectedKeys = [
            "HOME",
            "CFFIXED_USER_HOME",
            "SWIFTLY_HOME",
            "SWIFTLY_HOME_DIR",
            "SWIFTLY_TOOLCHAINS_DIR"
        ]
        
        for protectedKey in protectedKeys {
            processEnvironment[protectedKey] = inheritedEnvironment[protectedKey]
        }

        processEnvironment["SWIFTLY_BIN_DIR"] = environment.swiftly.executableURL
            .deletingLastPathComponent()
            .path(percentEncoded: false)

        return environment.swiftly.command(
            tool: tool,
            toolchain: environment.swiftVersion,
            arguments: toolArguments,
            workingDirectory: environment.packageRoot,
            environment: processEnvironment
        )
    }

}

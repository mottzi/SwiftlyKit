import Foundation

extension SwiftPM {

    func command(
        _ environment: LocalBuildEnvironment,
        swiftArguments: [String],
        workingDirectory: URL,
        additions: [String: String] = [:]
    ) -> SubprocessCommand {

        command(
            environment,
            tool: "swift",
            toolArguments: swiftArguments,
            workingDirectory: workingDirectory,
            additions: additions
        )
    }

    func command(
        _ environment: LocalBuildEnvironment,
        tool: String,
        toolArguments: [String],
        workingDirectory: URL,
        additions: [String: String]
    ) -> SubprocessCommand {

        let inheritedEnvironment = ProcessInfo.processInfo.environment
        var processEnvironment = inheritedEnvironment
        processEnvironment.merge(additions) { _, requested in requested }

        for protectedKey in [
            "HOME", "CFFIXED_USER_HOME", "SWIFTLY_HOME", "SWIFTLY_HOME_DIR", "SWIFTLY_TOOLCHAINS_DIR"
        ] {
            processEnvironment[protectedKey] = inheritedEnvironment[protectedKey]
        }

        processEnvironment["SWIFTLY_BIN_DIR"] = environment.swiftlyExecutableURL
            .deletingLastPathComponent().path

        return SubprocessCommand(
            executableURL: environment.swiftlyExecutableURL,
            arguments: ["run", tool] + toolArguments + ["+\(environment.swiftVersion)"],
            workingDirectory: workingDirectory,
            environment: processEnvironment
        )
    }

    func boundedDiagnostic(_ result: SubprocessResult) -> String {
        String((result.standardError + "\n" + result.standardOutput).suffix(16_384))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

}

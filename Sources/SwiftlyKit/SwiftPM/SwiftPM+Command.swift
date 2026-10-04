import Foundation

extension SwiftPM {

    /// Returns one bounded diagnostic from a subprocess result.
    static func boundedDiagnostic(_ result: SubprocessResult) -> String {
        let diagnostic = (result.standardError + "\n" + result.standardOutput)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard diagnostic.count > 16_384 else { return diagnostic }
        return String(diagnostic.prefix(12_000)) + "\n[diagnostic truncated]\n" + String(diagnostic.suffix(4_000))
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
    static func command(_ environment: LocalBuildEnvironment, swiftArguments: [String]) -> SubprocessCommand {

        var swiftArguments = swiftArguments
        if environment.hostSDK != nil, !swiftArguments.isEmpty {
            swiftArguments.insert(contentsOf: ["--manifest-cache", "none"], at: 1)
        }
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

        var processEnvironment = environment.hostSDK?.applying(to: processEnvironment) ?? processEnvironment

        if environment.swiftly.location == nil {
            if case .directory = environment.environmentStorage,
               let location = try? environment.environmentStorage.resolved() {
                processEnvironment = location.rebindingSwiftlyVariables(in: processEnvironment)
            } else {
                processEnvironment["SWIFTLY_BIN_DIR"] = environment.swiftly.executableURL
                    .deletingLastPathComponent()
                    .path(percentEncoded: false)
            }
        }

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

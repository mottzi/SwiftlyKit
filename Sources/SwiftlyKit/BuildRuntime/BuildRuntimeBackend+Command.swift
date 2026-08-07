import Foundation

extension BuildRuntimeBackend {
    
    func command(
        _ environment: BuildRuntimeEnvironment,
        swiftArguments: [String],
        workingDirectory: URL,
        additions: [String: String] = [:]
    ) -> BuildRuntimeCommand {
        command(
            environment,
            tool: "swift",
            toolArguments: swiftArguments,
            workingDirectory: workingDirectory,
            additions: additions
        )
    }
    
    func command(
        _ environment: BuildRuntimeEnvironment,
        tool: String,
        toolArguments: [String],
        workingDirectory: URL,
        additions: [String: String]
    ) -> BuildRuntimeCommand {
        
        let inheritedEnvironment = ProcessInfo.processInfo.environment
        var processEnvironment = inheritedEnvironment
        processEnvironment.merge(additions) { _, requested in requested }
        for protectedKey in [
            "HOME", "CFFIXED_USER_HOME", "SWIFTLY_HOME", "SWIFTLY_HOME_DIR", "SWIFTLY_TOOLCHAINS_DIR"
        ] {
            processEnvironment[protectedKey] = inheritedEnvironment[protectedKey]
        }
        processEnvironment["SWIFTLY_BIN_DIR"] = environment.swiftlyExecutable
            .deletingLastPathComponent().path
        
        return BuildRuntimeCommand(
            executable: environment.swiftlyExecutable,
            arguments: ["run", tool] + toolArguments + ["+\(environment.toolchainSelector.trimmingPrefix("+"))"],
            workingDirectory: workingDirectory,
            environment: processEnvironment
        )
    }
    
    func validate(_ environment: BuildRuntimeEnvironment) throws {
        guard environment.swiftlyExecutable.isFileURL,
              environment.sdkArtifactBundle.isFileURL,
              !environment.toolchainSelector.isEmpty,
              environment.sdkID == environment.architecture.swiftSDKSelector
        else { throw BuildRuntimeError.invalidEnvironment }
    }
    
    func boundedDiagnostic(_ result: BuildRuntimeProcessResult) -> String {
        String((result.standardError + "\n" + result.standardOutput).suffix(16_384))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
}

private extension String {
    
    func trimmingPrefix(_ prefix: Character) -> Substring {
        first == prefix ? dropFirst() : self[...]
    }
    
}

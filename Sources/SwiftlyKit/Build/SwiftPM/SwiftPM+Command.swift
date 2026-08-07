import Foundation

extension SwiftPM {
    
    func command(
        _ environment: SwiftPMEnvironment,
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
        _ environment: SwiftPMEnvironment,
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
        processEnvironment["SWIFTLY_BIN_DIR"] = environment.swiftlyExecutable
            .deletingLastPathComponent().path
        
        return SubprocessCommand(
            executableURL: environment.swiftlyExecutable,
            arguments: ["run", tool] + toolArguments + ["+\(environment.toolchainSelector.trimmingPrefix("+"))"],
            workingDirectory: workingDirectory,
            environment: processEnvironment
        )
    }
    
    func validate(_ environment: SwiftPMEnvironment) throws {
        guard environment.swiftlyExecutable.isFileURL,
              environment.sdkArtifactBundle.isFileURL,
              !environment.toolchainSelector.isEmpty,
              environment.sdkID == environment.architecture.swiftSDKSelector
        else { throw SwiftPMError.invalidEnvironment }
    }
    
    func boundedDiagnostic(_ result: SubprocessResult) -> String {
        String((result.standardError + "\n" + result.standardOutput).suffix(16_384))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    func outputHandler(_ handler: EventHandler?) -> SubprocessOutputHandler? {
        guard let handler else { return nil }
        return { stream, text in
            let publicStream: CommandOutput.Stream = switch stream {
                case .standardOutput: .standardOutput
                case .standardError: .standardError
            }
            await handler(.output(CommandOutput(stream: publicStream, text: text)))
        }
    }
    
}

private extension String {
    
    func trimmingPrefix(_ prefix: Character) -> Substring {
        first == prefix ? dropFirst() : self[...]
    }
    
}

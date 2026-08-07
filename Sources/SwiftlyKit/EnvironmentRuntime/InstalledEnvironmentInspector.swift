import Foundation

/// Inspects Swiftly and SwiftPM without changing selection or installed state.
struct InstalledEnvironmentInspector: Sendable {

    let run: EnvironmentCommandRunner
    let isToolchainUsable: @Sendable (SwiftVersion) -> Bool

    init(
        run: @escaping EnvironmentCommandRunner = EnvironmentProcess.run,
        isToolchainUsable: @escaping @Sendable (SwiftVersion) -> Bool =
            InstalledEnvironmentInspector.liveToolchainUsability
    ) {
        self.run = run
        self.isToolchainUsable = isToolchainUsable
    }

}

extension InstalledEnvironmentInspector {

    func inspect(
        swiftly: SwiftlyInstallation,
        selectedToolchain: SwiftVersion?
    ) async throws -> InstalledEnvironmentState {

        try Task.checkCancellation()

        let list = try await run(
            EnvironmentCommand(
                executableURL: swiftly.executableURL,
                arguments: ["list", "--format", "json"],
                workingDirectory: nil
            )
        )
        guard list.succeeded else { throw EnvironmentRuntimeError.inspectionFailed(list.combinedOutput) }

        let toolchains = Set(
            try Self.decodeStableToolchains(list.standardOutput).filter(isToolchainUsable)
        )
        guard let selectedToolchain, toolchains.contains(selectedToolchain) else {
            return InstalledEnvironmentState(toolchainVersions: toolchains, sdkIdentifiers: [])
        }

        let sdkList = try await run(Self.swiftCommand(
            swiftly: swiftly.executableURL,
            toolchain: selectedToolchain,
            arguments: ["sdk", "list"]
        ))
        guard sdkList.succeeded else { throw EnvironmentRuntimeError.inspectionFailed(sdkList.combinedOutput) }

        return InstalledEnvironmentState(
            toolchainVersions: toolchains,
            sdkIdentifiers: Self.decodeSDKIdentifiers(sdkList.standardOutput)
        )

    }

}

extension InstalledEnvironmentInspector {

    static func swiftCommand(
        swiftly: URL,
        toolchain: SwiftVersion,
        arguments: [String],
        workingDirectory: URL? = nil
    ) -> EnvironmentCommand {

        EnvironmentCommand(
            executableURL: swiftly,
            arguments: ["run", "swift"] + arguments + ["+\(toolchain)"],
            workingDirectory: workingDirectory
        )

    }

    static func decodeStableToolchains(_ output: String) throws -> Set<SwiftVersion> {

        struct Payload: Decodable {
            struct Toolchain: Decodable {
                struct Version: Decodable {
                    let name: String
                    let type: String
                }
                let version: Version
            }
            let toolchains: [Toolchain]
        }

        guard let data = output.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else { throw EnvironmentRuntimeError.invalidInspectionOutput }

        return Set(payload.toolchains.compactMap { item in
            guard item.version.type == "stable" else { return nil }
            return SwiftVersion(parsing: item.version.name)
        })

    }

    static func decodeSDKIdentifiers(_ output: String) -> Set<String> {

        Set(output.split(whereSeparator: \Character.isNewline).compactMap { line in
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value.localizedCaseInsensitiveContains("static-linux") else { return nil }
            return value
        })

    }
    
    static func liveToolchainUsability(_ version: SwiftVersion) -> Bool {
        
        let environment = ProcessInfo.processInfo.environment
        let toolchainsDirectory = environment["SWIFTLY_TOOLCHAINS_DIR"].map {
            URL(filePath: $0, directoryHint: .isDirectory)
        } ?? FileManager.default.homeDirectoryForCurrentUser.appending(
            path: "Library/Developer/Toolchains",
            directoryHint: .isDirectory
        )
        let executable = toolchainsDirectory.appending(
            path: "swift-\(version)-RELEASE.xctoolchain/usr/bin/swift"
        )
        return FileManager.default.isExecutableFile(atPath: executable.path)
    }

}

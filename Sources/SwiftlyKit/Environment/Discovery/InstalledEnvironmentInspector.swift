import Foundation

/// Inspects Swiftly and SwiftPM without changing selection or installed state.
struct InstalledEnvironmentInspector: Sendable {

    private(set) var runner: any SubprocessRunning = LiveSubprocessRunner()
    private(set) var isToolchainUsable: @Sendable (SwiftVersion) -> Bool = Self.liveToolchainUsability

}

extension InstalledEnvironmentInspector {

    func inspect(
        swiftly: SwiftlyInstallation,
        selectedToolchain: SwiftVersion
    ) async throws -> InstalledEnvironmentInventory {

        let toolchains = try await installedToolchains(swiftly: swiftly)
        
        guard toolchains.contains(selectedToolchain)
        else { return InstalledEnvironmentInventory(toolchains: toolchains, sdks: []) }
        
        let sdks = try await installedSDKs(swiftly: swiftly, toolchain: selectedToolchain)

        return InstalledEnvironmentInventory(toolchains: toolchains, sdks: sdks)
    }

    /// Inspects every usable stable toolchain without repeating the Swiftly registry query.
    func inspectAll(swiftly: SwiftlyInstallation) async throws -> InstalledEnvironmentInventory {

        let toolchains = try await installedToolchains(swiftly: swiftly)

        var sdks: [InstalledStaticLinuxSDK] = []
        for toolchain in toolchains {
            do { sdks += try await installedSDKs(swiftly: swiftly, toolchain: toolchain) }
            catch is CancellationError { throw CancellationError() }
            catch { continue }
        }

        return InstalledEnvironmentInventory(toolchains: toolchains, sdks: sdks)
    }

}

extension InstalledEnvironmentInspector {

    /// Decodes `swiftly list --format json`, excluding system, snapshot, and malformed entries.
    static func parseSwiftlyList(_ data: Data) throws -> [SwiftVersion] {

        let payload: ToolchainListPayload
        do { payload = try JSONDecoder().decode(ToolchainListPayload.self, from: data) }
        catch { throw InstalledEnvironmentError.invalidOutput }

        let toolchains: Set<SwiftVersion> = Set(payload.toolchains.compactMap { item in
            guard item.version.type == "stable" else { return nil }
            return SwiftVersion(parsing: item.version.name)
        })

        return toolchains.sorted(by: >)
    }

    /// Parses the line-oriented identifiers emitted by `swift sdk list`.
    static func parseSDKList(_ output: String, toolchainVersion: SwiftVersion) -> [InstalledStaticLinuxSDK] {

        Set(output.split(whereSeparator: \Character.isNewline).compactMap { line in
            let identifier = line.trimmingCharacters(in: .whitespacesAndNewlines)

            guard identifier.contains("_static-linux-") else { return nil }
            guard !identifier.contains(where: \Character.isWhitespace) else { return nil }

            return InstalledStaticLinuxSDK(toolchainVersion: toolchainVersion, identifier: identifier)
        })
        .sorted { $0.identifier < $1.identifier }
    }

    private func installedToolchains(swiftly: SwiftlyInstallation) async throws -> [SwiftVersion] {

        try Task.checkCancellation()

        let command = SubprocessCommand(
            executableURL: swiftly.executableURL,
            arguments: ["list", "--format", "json"]
        )

        let result = try await run(command)

        guard result.succeeded else { throw InstalledEnvironmentError.commandFailed(result.combinedOutput) }
        guard let data = result.standardOutput.data(using: .utf8) else { throw InstalledEnvironmentError.invalidOutput }

        return try Self.parseSwiftlyList(data).filter(isToolchainUsable)
    }

    private func installedSDKs(
        swiftly: SwiftlyInstallation,
        toolchain: SwiftVersion
    ) async throws -> [InstalledStaticLinuxSDK] {

        let command = swiftly.swiftCommand(
            toolchain: toolchain,
            arguments: ["sdk", "list"]
        )
        
        let result = try await run(command)

        guard result.succeeded else { throw InstalledEnvironmentError.commandFailed(result.combinedOutput) }

        return Self.parseSDKList(result.standardOutput, toolchainVersion: toolchain)
    }

    private func run(_ command: SubprocessCommand) async throws -> SubprocessResult {

        do {
            return try await runner.run(command)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw InstalledEnvironmentError.commandCouldNotRun(command.executableURL)
        }
    }

    static func liveToolchainUsability(_ version: SwiftVersion) -> Bool {
        
        let defaultToolchainsDirectory = FileManager.default.homeDirectoryForCurrentUser.appending(
            path: "Library/Developer/Toolchains",
            directoryHint: .isDirectory
        )
        
        let toolchainsDirectory = ProcessInfo.processInfo.environment["SWIFTLY_TOOLCHAINS_DIR"].map {
            URL(filePath: $0, directoryHint: .isDirectory)
        } ?? defaultToolchainsDirectory
        
        let executable = toolchainsDirectory.appending(path: "swift-\(version)-RELEASE.xctoolchain/usr/bin/swift")

        return FileManager.default.isExecutableFile(atPath: executable.path)
    }

}

extension InstalledEnvironmentInspector {

    private struct ToolchainListPayload: Decodable {

        let toolchains: [ToolchainPayload]

    }

    private struct ToolchainPayload: Decodable {

        let version: VersionPayload

    }

    private struct VersionPayload: Decodable {

        let name: String
        let type: String

    }

}

import Foundation

/// Inspects Swiftly and SwiftPM without changing selection or installed state.
struct InstalledEnvironmentInspector: Sendable {

    private(set) var runner: any SubprocessRunning = LiveSubprocessRunner()
    private(set) var isToolchainUsable: @Sendable (SwiftVersion) -> Bool = Self.liveToolchainUsability

}

extension InstalledEnvironmentInspector {

    func inspect(
        swiftly: SwiftlyInstallation,
        selectedToolchain: SwiftVersion?
    ) async throws -> InstalledEnvironmentInventory {

        let toolchains = try await installedToolchains(swiftly: swiftly)
        guard let selectedToolchain,
              toolchains.contains(where: { $0.version == selectedToolchain })
        else { return InstalledEnvironmentInventory(toolchains: toolchains, sdks: []) }
        let sdks = try await installedSDKs(swiftly: swiftly, toolchain: selectedToolchain)
        
        return InstalledEnvironmentInventory(toolchains: toolchains, sdks: sdks)
    }
    
    /// Inspects every usable stable toolchain without repeating the Swiftly registry query.
    func inspectAll(swiftly: SwiftlyInstallation) async throws -> InstalledEnvironmentInventory {
        
        let toolchains = try await installedToolchains(swiftly: swiftly)
        var sdks: [InstalledStaticLinuxSDK] = []
        for toolchain in toolchains {
            do { sdks += try await installedSDKs(swiftly: swiftly, toolchain: toolchain.version) }
            catch is CancellationError { throw CancellationError() }
            catch { continue }
        }

        return InstalledEnvironmentInventory(toolchains: toolchains, sdks: sdks)
    }

}

extension InstalledEnvironmentInspector {

    static func swiftCommand(
        swiftly: URL,
        toolchain: SwiftVersion,
        arguments: [String],
        workingDirectory: URL? = nil
    ) -> SubprocessCommand {
        
        SubprocessCommand(
            executableURL: swiftly,
            arguments: ["run", "swift"] + arguments + ["+\(toolchain)"],
            workingDirectory: workingDirectory
        )
    }
    
    private func installedToolchains(swiftly: SwiftlyInstallation) async throws -> [InstalledStableToolchain] {
        
        try Task.checkCancellation()
        
        let command = SubprocessCommand(
            executableURL: swiftly.executableURL,
            arguments: ["list", "--format", "json"]
        )
        
        let result = try await run(command)
        guard result.succeeded else { throw InstalledEnvironmentError.commandFailed(result.combinedOutput) }
        guard let data = result.standardOutput.data(using: .utf8) else { throw InstalledEnvironmentError.invalidOutput }
        
        do { return try InstalledStableToolchain.parseSwiftlyList(data).filter { isToolchainUsable($0.version) } }
        catch { throw InstalledEnvironmentError.invalidOutput }
    }
    
    private func installedSDKs(
        swiftly: SwiftlyInstallation,
        toolchain: SwiftVersion
    ) async throws -> [InstalledStaticLinuxSDK] {
        
        let result = try await run(Self.swiftCommand(
            swiftly: swiftly.executableURL,
            toolchain: toolchain,
            arguments: ["sdk", "list"]
        ))
        guard result.succeeded else { throw InstalledEnvironmentError.commandFailed(result.combinedOutput) }
        return InstalledStaticLinuxSDK.parseList(
            result.standardOutput,
            toolchainVersion: toolchain
        )
    }

    private func run(_ command: SubprocessCommand) async throws -> SubprocessResult {

        do { return try await runner.run(command) }
        catch is CancellationError { throw CancellationError() }
        catch {
            if Task.isCancelled { throw CancellationError() }
            throw InstalledEnvironmentError.commandCouldNotRun(command.executableURL)
        }
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

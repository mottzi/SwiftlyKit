import Foundation

/// Inspects Swiftly and SwiftPM without changing selection or installed state.
struct InstalledEnvironmentInspector {

    private(set) var runner: any SubprocessRunning = LiveSubprocessRunner()
    private(set) var isToolchainUsable: @Sendable (SwiftVersion) -> Bool = Self.liveToolchainUsability

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

    /// Inspects registered toolchains and shared SDK state for exact removal safety.
    /// It prefers the requested toolchain for SDK inspection and does not mutate state.
    func inspectForRemoval(
        swiftly: SwiftlyInstallation,
        toolchain preferredToolchain: SwiftVersion?,
        includeSDKs: Bool
    ) async throws -> EnvironmentRemovalInventory {

        try Task.checkCancellation()

        let payload = try await rawToolchains(swiftly: swiftly)
        let registered = Self.registeredToolchains(from: payload)
        guard includeSDKs else {
            return EnvironmentRemovalInventory(
                toolchains: registered,
                sdks: [],
                sdkInspection: .notRequested
            )
        }

        let candidates = Self.sdkManagerCandidates(
            registered: registered,
            preferred: preferredToolchain
        )

        if customSDKRegistryIsAbsent(swiftly) {
            return EnvironmentRemovalInventory(
                toolchains: registered,
                sdks: [],
                sdkInspection: .absent
            )
        }

        for manager in candidates {
            do {
                let sdks = try await registeredSDKs(swiftly: swiftly, manager: manager)
                return EnvironmentRemovalInventory(
                    toolchains: registered,
                    sdks: sdks,
                    sdkInspection: .available(manager: manager)
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as InstalledEnvironmentError {
                if case .invalidOutput = error {
                    return EnvironmentRemovalInventory(
                        toolchains: registered,
                        sdks: [],
                        sdkInspection: .malformed
                    )
                }
            }
        }

        return EnvironmentRemovalInventory(
            toolchains: registered,
            sdks: [],
            sdkInspection: .unavailable
        )
    }

}

extension InstalledEnvironmentInspector {

    private func installedToolchains(swiftly: SwiftlyInstallation) async throws -> [SwiftVersion] {

        let data = try await swiftlyListData(swiftly: swiftly)

        let usability: @Sendable (SwiftVersion) -> Bool
        if let location = swiftly.location {
            usability = { Self.liveToolchainUsability($0, in: location) }
        } else {
            usability = isToolchainUsable
        }

        return try Self.parseSwiftlyList(data).filter(usability)
    }

    private func rawToolchains(swiftly: SwiftlyInstallation) async throws -> [ToolchainPayload] {

        let data = try await swiftlyListData(swiftly: swiftly)

        do { return try JSONDecoder().decode(ToolchainListPayload.self, from: data).toolchains }
        catch { throw InstalledEnvironmentError.invalidOutput }
    }

    private func installedSDKs(
        swiftly: SwiftlyInstallation,
        toolchain: SwiftVersion
    ) async throws -> [InstalledStaticLinuxSDK] {

        guard !customSDKRegistryIsAbsent(swiftly) else { return [] }

        let output = try await sdkListOutput(swiftly: swiftly, toolchain: toolchain)
        return Self.parseSDKList(output, toolchainVersion: toolchain)
    }

    private func registeredSDKs(swiftly: SwiftlyInstallation, manager: SwiftVersion) async throws -> [RegisteredSDK] {

        guard !customSDKRegistryIsAbsent(swiftly) else { return [] }

        let output = try await sdkListOutput(swiftly: swiftly, toolchain: manager)
        return try Self.parseRegisteredSDKList(output)
    }

    private func swiftlyListData(swiftly: SwiftlyInstallation) async throws -> Data {

        try Task.checkCancellation()

        let command = SubprocessCommand(
            executableURL: swiftly.executableURL,
            arguments: ["list", "--format", "json"],
            environment: swiftly.processEnvironment
        )
        let result = try await run(command)

        guard result.succeeded else { throw InstalledEnvironmentError.commandFailed(result.combinedOutput) }
        guard let data = result.standardOutput.data(using: .utf8) else {
            throw InstalledEnvironmentError.invalidOutput
        }
        return data
    }

    private func sdkListOutput(
        swiftly: SwiftlyInstallation,
        toolchain: SwiftVersion
    ) async throws -> String {

        let command = swiftly.command(
            tool: "swift",
            toolchain: toolchain,
            arguments: swiftly.sdkCommandArguments(["sdk", "list"])
        )
        let result = try await run(command)

        guard result.succeeded else { throw InstalledEnvironmentError.commandFailed(result.combinedOutput) }
        return result.standardOutput
    }

    private func customSDKRegistryIsAbsent(_ swiftly: SwiftlyInstallation) -> Bool {

        guard let sdkDirectory = swiftly.location?.swiftPMSDKDirectory else { return false }

        var isDirectory: ObjCBool = false
        return !FileManager.default.fileExists(
            atPath: sdkDirectory.path(percentEncoded: false),
            isDirectory: &isDirectory
        )
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

}

extension InstalledEnvironmentInspector {

    /// Decodes `swiftly list --format json`, excluding system, snapshot, and malformed entries.
    private static func parseSwiftlyList(_ data: Data) throws -> [SwiftVersion] {

        let payload: ToolchainListPayload
        do { payload = try JSONDecoder().decode(ToolchainListPayload.self, from: data) }
        catch { throw InstalledEnvironmentError.invalidOutput }

        let toolchains: Set<SwiftVersion> = Set(payload.toolchains.compactMap { item in
            guard item.version.type == "stable" else { return nil }
            return SwiftVersion(item.version.name)
        })

        return toolchains.sorted(by: >)
    }

    /// Parses the line-oriented identifiers emitted by `swift sdk list`.
    private static func parseSDKList(_ output: String, toolchainVersion: SwiftVersion) -> [InstalledStaticLinuxSDK] {

        Set(output.split(whereSeparator: \Character.isNewline).compactMap { line in
            let identifier = line.trimmingCharacters(in: .whitespacesAndNewlines)

            guard identifier.contains("_static-linux-") else { return nil }
            guard !identifier.contains(where: \Character.isWhitespace) else { return nil }

            return InstalledStaticLinuxSDK(toolchainVersion: toolchainVersion, identifier: identifier)
        })
        .sorted { $0.identifier < $1.identifier }
    }

    /// Parses every registered SDK identifier for removal safety. Unlike the
    /// selection parser, this intentionally keeps non-Static-Linux identifiers
    /// and rejects any nonempty malformed line.
    private static func parseRegisteredSDKList(_ output: String) throws -> [RegisteredSDK] {

        var identifiers = Set<String>()
        for line in output.split(omittingEmptySubsequences: false, whereSeparator: \Character.isNewline) {
            let identifier = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard identifier.isEmpty || isSafeSDKIdentifier(identifier) else {
                throw InstalledEnvironmentError.invalidOutput
            }
            guard !identifier.isEmpty else { continue }
            identifiers.insert(identifier)
        }

        return identifiers
            .map { RegisteredSDK(identifier: $0) }
            .sorted { $0.identifier < $1.identifier }
    }

    private static func registeredToolchains(from payload: [ToolchainPayload]) -> [RegisteredToolchain] {

        let stable = payload.compactMap { item -> (SwiftVersion, ToolchainPayload)? in
            guard item.version.type == "stable",
                  let version = SwiftVersion(item.version.name)
            else { return nil }
            return (version, item)
        }

        let versions = Set(stable.map(\.0)).sorted(by: >)
        return versions.map { version in
            let matches = stable.filter { $0.0 == version }.map(\.1)
            guard matches.count == 1, let item = matches.first else {
                return RegisteredToolchain(
                    version: version,
                    isInUse: false,
                    isDefault: false,
                    selectionStateIsKnown: false
                )
            }
            return RegisteredToolchain(
                version: version,
                isInUse: item.inUse ?? false,
                isDefault: item.isDefault ?? false,
                selectionStateIsKnown: item.inUse != nil && item.isDefault != nil
            )
        }
    }

    private static func sdkManagerCandidates(
        registered: [RegisteredToolchain],
        preferred: SwiftVersion?
    ) -> [SwiftVersion] {

        let others = registered.map(\.version).filter { $0 != preferred }.sorted(by: >)
        if let preferred, registered.contains(where: { $0.version == preferred }) {
            return [preferred] + others
        }
        return others
    }

}

extension InstalledEnvironmentInspector {

    private static func liveToolchainUsability(_ version: SwiftVersion) -> Bool {
        guard let location = try? EnvironmentStorage.standard.resolved() else { return false }
        return liveToolchainUsability(version, in: location)
    }

    private static func liveToolchainUsability(_ version: SwiftVersion, in location: EnvironmentStorageLocation) -> Bool {

        let toolchainsDirectory = location.toolchainsDirectory
        let executable = toolchainsDirectory.appending(path: "swift-\(version)-RELEASE.xctoolchain/usr/bin/swift")

        guard FileManager.default.isExecutableFile(atPath: executable.path(percentEncoded: false)) else {
            return false
        }
        guard case .directory = location.storage else { return true }

        guard let resolvedToolchainsDirectory = try? CanonicalFileURL.resolve(toolchainsDirectory),
              let resolvedExecutable = try? CanonicalFileURL.resolve(executable),
              resolvedExecutable.pathComponents.starts(with: resolvedToolchainsDirectory.pathComponents)
        else { return false }

        return true
    }

}

extension InstalledEnvironmentInspector {

    private struct ToolchainListPayload: Decodable {
        let toolchains: [ToolchainPayload]
    }

    private struct ToolchainPayload: Decodable {
        let version: VersionPayload
        let inUse: Bool?
        let isDefault: Bool?
    }

    private struct VersionPayload: Decodable {
        let name: String
        let type: String
    }

}

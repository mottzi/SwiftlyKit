import Foundation

/// A compatible Swiftly executable discovered without changing user state.
struct SwiftlyInstallation: Equatable {

    let executableURL: URL
    let location: EnvironmentStorageLocation?

    /// Inherited process values bound to the detected Swiftly namespace.
    var processEnvironment: [String: String]? {
        guard let location else { return nil }
        return location.processEnvironment
    }

    init(executableURL: URL) {
        self.executableURL = executableURL
        self.location = nil
    }

    private init(executableURL: URL, location: EnvironmentStorageLocation) {
        self.executableURL = executableURL
        self.location = location
    }

    static func detect(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        versionProbe: @Sendable (URL) async throws -> String = {
            try await SwiftlyInstallation.liveVersionProbe(at: $0)
        }
    ) async throws -> SwiftlyInstallation? {

        try Task.checkCancellation()

        let candidates = candidateURLs(environment: environment, homeDirectory: homeDirectory)
        guard let executableURL = candidates.first(where: isExecutableRegularFile(at:)) else { return nil }

        let versionOutput: String
        do {
            versionOutput = try await versionProbe(executableURL)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw SwiftlyKitError.incompatibleSwiftly
        }

        try Task.checkCancellation()
        guard isCompatibleVersion(versionOutput) else { throw SwiftlyKitError.incompatibleSwiftly }

        return SwiftlyInstallation(executableURL: executableURL)
    }

    /// Detects a compatible Swiftly executable in one deterministic namespace.
    static func detect(
        storage: EnvironmentStorage,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        versionProbe: (@Sendable (URL) async throws -> String)? = nil
    ) async throws -> SwiftlyInstallation? {

        try Task.checkCancellation()

        let location = try storage.resolved(homeDirectory: homeDirectory)
        let executableURL = location.binDirectory.appending(path: "swiftly")
        guard isExecutableRegularFile(at: executableURL) else { return nil }

        let probe = versionProbe ?? { url in
            return try await SwiftlyInstallation.liveVersionProbe(
                at: url,
                environment: location.processEnvironment
            )
        }
        let versionOutput: String
        do {
            versionOutput = try await probe(executableURL)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw SwiftlyKitError.incompatibleSwiftly
        }

        try Task.checkCancellation()
        guard isCompatibleVersion(versionOutput) else { throw SwiftlyKitError.incompatibleSwiftly }

        return SwiftlyInstallation(executableURL: executableURL, location: location)
    }

}

extension SwiftlyInstallation {

    /// Adds the selected namespace's SDK registry to a Swift SDK command.
    /// Standard storage leaves SwiftPM's default registry unchanged.
    func sdkCommandArguments(_ arguments: [String]) -> [String] {

        guard let sdkDirectory = location?.swiftPMSDKDirectory else { return arguments }
        return arguments + [
            "--swift-sdks-path",
            sdkDirectory.path(percentEncoded: false)
        ]
    }

    /// Creates one selected-tool command with the supplied process environment and sensitive keys.
    func command(
        tool: String,
        toolchain: SwiftVersion,
        arguments: [String],
        workingDirectory: URL? = nil,
        environment: [String: String]? = nil,
        sensitiveEnvironmentKeys: Set<String> = []
    ) -> SubprocessCommand {

        var processEnvironment = environment
        if let location {
            var values = processEnvironment ?? ProcessInfo.processInfo.environment
            for name in values.keys.filter({ $0.hasPrefix("SWIFTLY_") }) {
                values[name] = nil
            }
            for (name, value) in location.environment {
                values[name] = value
            }
            processEnvironment = values
        }

        return SubprocessCommand(
            executableURL: executableURL,
            arguments: ["run", tool] + arguments + ["+\(toolchain)"],
            workingDirectory: workingDirectory,
            environment: processEnvironment,
            sensitiveEnvironmentKeys: sensitiveEnvironmentKeys
        )
    }

}

extension SwiftlyInstallation {

    private static func candidateURLs(environment: [String: String], homeDirectory: URL) -> [URL] {

        var candidates: [URL] = []
        if let binDirectory = environment["SWIFTLY_BIN_DIR"], binDirectory.hasPrefix("/") {
            let binDirectoryURL = URL(filePath: binDirectory)
            candidates.append(binDirectoryURL.appending(path: "swiftly"))
        }
        candidates.append(homeDirectory.appending(path: ".swiftly/bin/swiftly"))

        var canonicalCandidates: [URL] = []
        for candidate in candidates {
            let canonicalCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL
            guard !canonicalCandidates.contains(canonicalCandidate) else { continue }
            canonicalCandidates.append(canonicalCandidate)
        }

        return canonicalCandidates
    }

    private static func isExecutableRegularFile(at url: URL) -> Bool {

        guard url.isFileURL else { return false }
        guard url.path(percentEncoded: false).hasPrefix("/") else { return false }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: url.path(percentEncoded: false),
            isDirectory: &isDirectory
        ) else { return false }
        guard !isDirectory.boolValue else { return false }
        
        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: url.path(percentEncoded: false)
        ) else { return false }
        guard let type = attributes[.type] as? FileAttributeType else { return false }
        guard type == .typeRegular else { return false }

        return FileManager.default.isExecutableFile(atPath: url.path(percentEncoded: false))
    }

    private static func isCompatibleVersion(_ output: String) -> Bool {

        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = trimmed.split(separator: ".", omittingEmptySubsequences: false)

        guard components.count == 3 else { return false }
        guard let version = SwiftVersion(trimmed) else { return false }

        return version.major >= 1
    }

}

extension SwiftlyInstallation {

    private static func liveVersionProbe(
        at executableURL: URL,
        environment: [String: String]? = nil
    ) async throws -> String {

        try Task.checkCancellation()

        let command = SubprocessCommand(
            executableURL: executableURL,
            arguments: ["--version"],
            environment: environment
        )
        let result = try await LiveSubprocessRunner().run(command)

        try Task.checkCancellation()
        guard result.succeeded else { throw SwiftlyKitError.incompatibleSwiftly }

        return result.standardOutput
    }

}

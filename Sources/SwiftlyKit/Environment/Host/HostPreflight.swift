import Foundation

/// Read-only validation of the host and its active macOS SDK.
struct HostPreflight: Sendable {

    private(set) var hostFacts: HostFacts = Self.liveHostFacts

    private(set) var sdkProbe: @Sendable () async throws -> URL = {
        try await HostPreflight.liveSDKProbe()
    }

    /// Validates the host and its active SDK.
    func check() async throws {

        try Task.checkCancellation()

        guard hostFacts.isAppleSilicon,
              hostFacts.operatingSystemVersion.majorVersion >= 13
        else { throw SwiftlyKitError.unsupportedHost }

        let sdkURL: URL
        do {
            sdkURL = try await sdkProbe()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw SwiftlyKitError.developerToolsUnavailable
        }

        try Task.checkCancellation()

        let canonicalSDKURL = sdkURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        
        guard Self.isUsableSDK(at: canonicalSDKURL) else { throw SwiftlyKitError.developerToolsUnavailable }
    }

}

extension HostPreflight {

    private static func isUsableSDK(at url: URL) -> Bool {

        guard url.isFileURL else { return false }
        guard url.path.hasPrefix("/") else { return false }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return false }
        guard isDirectory.boolValue else { return false }

        return FileManager.default.isReadableFile(atPath: url.path)
    }

}

extension HostPreflight {

    private static var liveHostFacts: HostFacts {
        #if arch(arm64)
            let isAppleSilicon = true
        #else
            let isAppleSilicon = false
        #endif

        return HostFacts(
            isAppleSilicon: isAppleSilicon,
            operatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersion
        )
    }

    private static func liveSDKProbe() async throws -> URL {

        try Task.checkCancellation()

        let command = SubprocessCommand(
            executableURL: URL(filePath: "/usr/bin/xcrun"),
            arguments: ["--sdk", "macosx", "--show-sdk-path"]
        )
        let result = try await LiveSubprocessRunner().run(command)

        try Task.checkCancellation()
        guard result.succeeded else { throw SwiftlyKitError.developerToolsUnavailable }

        let path = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/") else { throw SwiftlyKitError.developerToolsUnavailable }

        try Task.checkCancellation()
        return URL(filePath: path)
    }

}

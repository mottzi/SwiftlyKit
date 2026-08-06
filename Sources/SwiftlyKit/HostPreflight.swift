import Foundation
import Subprocess

/// Read-only validation of the host and its active macOS SDK.
struct HostPreflight: Sendable {
    
    let hostFacts: HostFacts
    let sdkProbe: @Sendable () async throws -> URL
    
    init(
        hostFacts: HostFacts = .live,
        sdkProbe: @escaping @Sendable () async throws -> URL = HostPreflight.liveSDKProbe
    ) {
        self.hostFacts = hostFacts
        self.sdkProbe = sdkProbe
    }
    
}

extension HostPreflight {
    
    /// Validates the host before returning the canonical active SDK directory.
    func check() async throws -> URL {
        
        try Task.checkCancellation()
        
        guard hostFacts.isAppleSilicon else { throw SwiftlyKitError.unsupportedHost }
        guard hostFacts.operatingSystemVersion.majorVersion >= 13 else { throw SwiftlyKitError.unsupportedHost }
        
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
        
        let canonicalSDKURL = sdkURL.resolvingSymlinksInPath().standardizedFileURL
        guard Self.isUsableSDK(at: canonicalSDKURL) else { throw SwiftlyKitError.developerToolsUnavailable }
        return canonicalSDKURL
    }
    
}

extension HostPreflight {
    
    static func liveSDKProbe() async throws -> URL {
        
        try Task.checkCancellation()
        
        do {
            var platformOptions = PlatformOptions()
            platformOptions.createSession = true
            platformOptions.teardownSequence = [
                .gracefulShutDown(toProcessGroup: true, allowedDurationToNextStep: .seconds(1))
            ]
            
            let result = try await Subprocess.run(
                .path("/usr/bin/xcrun"),
                arguments: ["--sdk", "macosx", "--show-sdk-path"],
                environment: .inherit,
                platformOptions: platformOptions,
                output: .string(limit: 4 * 1024),
                error: .string(limit: 4 * 1024)
            )
            
            try Task.checkCancellation()
            
            guard result.terminationStatus.isSuccess else { throw SwiftlyKitError.developerToolsUnavailable }
            
            let path = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            guard path.hasPrefix("/") else { throw SwiftlyKitError.developerToolsUnavailable }
            
            try Task.checkCancellation()
            return URL(filePath: path)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SwiftlyKitError {
            if Task.isCancelled { throw CancellationError() }
            throw error
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw SwiftlyKitError.developerToolsUnavailable
        }
    }
    
    private static func isUsableSDK(at url: URL) -> Bool {
        
        guard url.isFileURL, url.path.hasPrefix("/") else { return false }
        
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return false }
        guard isDirectory.boolValue else { return false }
        
        return FileManager.default.isReadableFile(atPath: url.path)
    }
    
}

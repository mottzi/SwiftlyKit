import Foundation
import Subprocess
import System

/// A compatible Swiftly executable discovered without changing user state.
struct SwiftlyInstallation: Equatable, Sendable {
    
    let executableURL: URL
    let version: String
    
}

extension SwiftlyInstallation {
    
    static func detect(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        versionProbe: @Sendable (URL) async throws -> String = SwiftlyInstallation.liveVersionProbe
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
        guard let version = compatibleVersion(from: versionOutput) else {
            throw SwiftlyKitError.incompatibleSwiftly
        }
        
        return SwiftlyInstallation(executableURL: executableURL, version: version)
    }
    
    private static func candidateURLs(
        environment: [String: String],
        homeDirectory: URL
    ) -> [URL] {
        
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
        
        guard url.isFileURL, url.path.hasPrefix("/") else { return false }
        
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return false }
        guard !isDirectory.boolValue else { return false }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return false }
        guard let type = attributes[.type] as? FileAttributeType, type == .typeRegular else { return false }
        
        return FileManager.default.isExecutableFile(atPath: url.path)
    }
    
    private static func compatibleVersion(from output: String) -> String? {
        
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3 else { return nil }
        guard components.allSatisfy(\.isASCIIDecimal) else { return nil }
        guard let major = UInt(components[0]), major >= 1 else { return nil }
        guard UInt(components[1]) != nil else { return nil }
        guard UInt(components[2]) != nil else { return nil }
        return trimmed
    }
    
}

extension SwiftlyInstallation {
    
    static func liveVersionProbe(at executableURL: URL) async throws -> String {
        
        try Task.checkCancellation()
        
        do {
            let result = try await Subprocess.run(
                .path(FilePath(executableURL.path)),
                arguments: ["--version"],
                environment: .inherit,
                platformOptions: .swiftlyKitProcess,
                output: .string(limit: 4 * 1024),
                error: .string(limit: 4 * 1024)
            )
            
            try Task.checkCancellation()
            guard result.terminationStatus.isSuccess else { throw SwiftlyKitError.incompatibleSwiftly }
            
            try Task.checkCancellation()
            return result.standardOutput
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SwiftlyKitError {
            if Task.isCancelled { throw CancellationError() }
            throw error
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw SwiftlyKitError.incompatibleSwiftly
        }
    }
    
}

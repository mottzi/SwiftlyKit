import Foundation

/// Text-only package requirements available before manifest evaluation.
struct PackageRequirements: Equatable, Sendable {
    
    let packageRoot: URL
    let toolsVersion: SwiftVersion
    let swiftVersion: String?
    let swiftVersionFileURL: URL?
    
    /// Validates a package root and reads the inputs needed to select a toolchain.
    static func load(at packageRoot: URL) throws -> PackageRequirements {
        
        guard packageRoot.isFileURL else { throw LoadingError.invalidPackageRoot(packageRoot) }
        
        let canonicalRoot = packageRoot.resolvingSymlinksInPath().standardizedFileURL
        guard isDirectory(at: canonicalRoot) else { throw LoadingError.invalidPackageRoot(packageRoot) }
        
        let manifestURL = canonicalRoot.appending(path: "Package.swift")
        let manifestExists = FileManager.default.fileExists(atPath: manifestURL.path)
        guard manifestExists else { throw LoadingError.invalidPackageRoot(packageRoot) }
        guard isRegularReadableFile(at: manifestURL) else { throw LoadingError.unreadableManifest(manifestURL) }
        
        let manifest: String
        do {
            let data = try Data(contentsOf: manifestURL)
            let decoded = String(data: data, encoding: .utf8)
            guard let decoded else { throw LoadingError.unreadableManifest(manifestURL) }
            manifest = decoded
        } catch let error as LoadingError {
            throw error
        } catch {
            throw LoadingError.unreadableManifest(manifestURL)
        }
        
        let toolsVersion = try parseToolsVersion(from: manifest)
        let swiftVersionFile = try nearestSwiftVersionFile(startingAt: canonicalRoot)
        
        return PackageRequirements(
            packageRoot: canonicalRoot,
            toolsVersion: toolsVersion,
            swiftVersion: swiftVersionFile?.value,
            swiftVersionFileURL: swiftVersionFile?.url
        )
    }
    
}

extension PackageRequirements {
    
    private static func isDirectory(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
    
    private static func isRegularReadableFile(at url: URL) -> Bool {
        
        guard FileManager.default.fileExists(atPath: url.path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let type = attributes[.type] as? FileAttributeType,
              type == .typeRegular
        else { return false }
        
        return FileManager.default.isReadableFile(atPath: url.path)
    }
    
    private static func parseToolsVersion(from manifest: String) throws -> SwiftVersion {
        
        var hasEarlierNonWhitespaceLine = false
        
        for line in manifest.split(whereSeparator: \.isNewline) {
            if line.allSatisfy({ $0.isWhitespace && !$0.isNewline }) { continue }
            
            if let toolsVersion = parseToolsVersionDirective(in: line) {
                if hasEarlierNonWhitespaceLine, toolsVersion < SwiftVersion(major: 6, minor: 0, patch: 0) {
                    throw LoadingError.toolsVersionMustBeFirstLine(toolsVersion)
                }
                return toolsVersion
            }
            
            hasEarlierNonWhitespaceLine = true
        }
        
        throw LoadingError.malformedToolsVersion
    }
    
    private static func parseToolsVersionDirective(in line: Substring) -> SwiftVersion? {
        
        let leadingTrimmed = line.drop(while: isHorizontalWhitespace)
        guard leadingTrimmed.hasPrefix("//") else { return nil }
        
        let label = "swift-tools-version:"
        let afterCommentMarker = leadingTrimmed.dropFirst(2)
        let labelStart = afterCommentMarker.drop(while: isHorizontalWhitespace)
        guard labelStart.count >= label.count else { return nil }
        guard labelStart.prefix(label.count).lowercased() == label else { return nil }
        
        let valueStart = labelStart.dropFirst(label.count)
        let valueBeforeTerminator: Substring
        if let semicolon = valueStart.firstIndex(of: ";") {
            valueBeforeTerminator = valueStart[..<semicolon]
        } else {
            valueBeforeTerminator = valueStart
        }
        let value = valueBeforeTerminator
            .drop(while: isHorizontalWhitespace)
            .reversed()
            .drop(while: isHorizontalWhitespace)
            .reversed()
        
        return SwiftVersion(parsing: String(value))
    }
    
    private static func isHorizontalWhitespace(_ character: Character) -> Bool {
        character.isWhitespace && !character.isNewline
    }
    
    private static func nearestSwiftVersionFile(startingAt packageRoot: URL) throws -> (value: String, url: URL)? {
        
        var directory = packageRoot
        
        while true {
            let candidate = directory.appending(path: ".swift-version")
            
            if FileManager.default.fileExists(atPath: candidate.path) {
                let canonicalCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL
                
                let isReadable = isRegularReadableFile(at: candidate)
                guard isReadable else { throw LoadingError.unreadableSwiftVersionFile(canonicalCandidate) }
                
                do {
                    let data = try Data(contentsOf: candidate)
                    let value = String(data: data, encoding: .utf8)
                    guard let value else { throw LoadingError.unreadableSwiftVersionFile(canonicalCandidate) }
                    
                    return (value.trimmingCharacters(in: .whitespacesAndNewlines), canonicalCandidate)
                } catch let error as LoadingError {
                    throw error
                } catch {
                    throw LoadingError.unreadableSwiftVersionFile(canonicalCandidate)
                }
            }
            
            let parent = directory.deletingLastPathComponent().standardizedFileURL
            guard parent.path != directory.path else { break }
            
            directory = parent
        }
        
        return nil
    }
    
}

extension PackageRequirements {
    
    enum LoadingError: Error, Equatable {
        case invalidPackageRoot(URL)
        case unreadableManifest(URL)
        case malformedToolsVersion
        case toolsVersionMustBeFirstLine(SwiftVersion)
        case unreadableSwiftVersionFile(URL)
    }
    
}

extension PackageRequirements.LoadingError {
    
    var swiftlyKitError: SwiftlyKitError {
        switch self {
            case .invalidPackageRoot(let url): .invalidPackageRoot(url)
            case .unreadableManifest(let url): .invalidPackageRoot(url.deletingLastPathComponent())
            case .malformedToolsVersion: .malformedToolsVersion
            case .toolsVersionMustBeFirstLine(let version): .unsupportedToolsVersion(version)
            case .unreadableSwiftVersionFile: .staleAssessment
        }
    }
    
}

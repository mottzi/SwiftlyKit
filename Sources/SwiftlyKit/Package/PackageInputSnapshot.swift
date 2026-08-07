import Foundation

/// Byte-for-byte package inputs that authorize environment preparation.
struct PackageInputSnapshot: Equatable, Sendable {
    
    let manifest: Data
    let swiftVersionFile: Data?
    
    static func capture(_ requirements: PackageRequirements) throws -> PackageInputSnapshot {
        do {
            return PackageInputSnapshot(
                manifest: try Data(contentsOf: requirements.packageRoot.appending(path: "Package.swift")),
                swiftVersionFile: try requirements.swiftVersionFileURL.map { try Data(contentsOf: $0) }
            )
        } catch {
            throw SwiftlyKitError.invalidPackageRoot(requirements.packageRoot)
        }
    }
    
}

import Foundation

/// Byte-for-byte package inputs that authorize environment preparation.
struct PackageInputSnapshot: Equatable, Sendable {
    
    let requirements: PackageRequirements
    let manifest: Data
    let swiftVersionFile: Data?
    
    static func capture(_ requirements: PackageRequirements) throws -> PackageInputSnapshot {
        do {
            return PackageInputSnapshot(
                requirements: requirements,
                manifest: try Data(contentsOf: requirements.packageRoot.appending(path: "Package.swift")),
                swiftVersionFile: try requirements.swiftVersionFileURL.map { try Data(contentsOf: $0) }
            )
        } catch {
            throw SwiftlyKitError.invalidPackageRoot(requirements.packageRoot)
        }
    }
    
    func validateCurrent() throws {
        do {
            let currentRequirements = try PackageRequirements.load(at: requirements.packageRoot)
            guard try Self.capture(currentRequirements) == self else {
                throw SwiftlyKitError.staleAssessment
            }
        } catch {
            throw SwiftlyKitError.staleAssessment
        }
    }
    
}

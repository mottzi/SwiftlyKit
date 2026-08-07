extension EnvironmentAssessment {
    
    /// Rejects preparation when the package inputs used for assessment have changed.
    func validateUnchangedInputs() throws {
        
        let requirements: PackageRequirements
        do {
            requirements = try PackageRequirements.load(at: packageRoot)
        } catch {
            throw SwiftlyKitError.staleAssessment
        }
        guard requirements.packageRoot == packageRoot,
              requirements.toolsVersion == toolsVersion,
              requirements.swiftVersion == swiftVersionPreference,
              requirements.swiftVersionFileURL == swiftVersionFileURL
        else { throw SwiftlyKitError.staleAssessment }
        let snapshot: PackageInputSnapshot
        do {
            snapshot = try PackageInputSnapshot.capture(requirements)
        } catch {
            throw SwiftlyKitError.staleAssessment
        }
        guard snapshot.manifest == manifestContents,
              snapshot.swiftVersionFile == swiftVersionFileContents
        else { throw SwiftlyKitError.staleAssessment }
    }
    
}

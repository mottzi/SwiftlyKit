/// Read-only exact environment assessments from one package, catalog, and installed-state observation.
/// Elements contain each compatible Swift version once in newest-first order.
/// The collection is empty if no official stable release is compatible.
public struct EnvironmentChoices: Sendable, RandomAccessCollection {

    /// The assessment stored at each collection position.
    public typealias Element = EnvironmentAssessment

    /// The integer position of an assessment.
    public typealias Index = Int

    private let assessments: [EnvironmentAssessment]
    private let assessmentsByVersion: [SwiftVersion: EnvironmentAssessment]
    private let toolsVersion: SwiftVersion
    private let swiftVersionPreference: String?
    private let architecture: LinuxArchitecture
    private let releases: [OfficialStableRelease]
    private let inventory: InstalledEnvironmentInventory

    init(
        assessments: [EnvironmentAssessment],
        toolsVersion: SwiftVersion,
        swiftVersionPreference: String?,
        architecture: LinuxArchitecture,
        releases: [OfficialStableRelease],
        inventory: InstalledEnvironmentInventory
    ) {

        self.assessments = assessments
        self.assessmentsByVersion = Dictionary(uniqueKeysWithValues: assessments.map {
            ($0.swiftVersion, $0)
        })
        self.toolsVersion = toolsVersion
        self.swiftVersionPreference = swiftVersionPreference
        self.architecture = architecture
        self.releases = releases
        self.inventory = inventory
    }

    /// Applies an automatic or exact toolchain selection to the captured observation without more I/O.
    /// Throws if the selection is not valid for the package or target.
    public func select(_ selection: ToolchainSelection) throws(SwiftlyKitError) -> EnvironmentAssessment {

        let release: OfficialStableRelease
        do {
            release = try EnvironmentSelectionPolicy.select(
                toolchain: selection,
                toolsVersion: toolsVersion,
                swiftVersionPreference: swiftVersionPreference,
                architecture: architecture,
                releases: releases,
                inventory: inventory
            )
        } catch {
            throw error.swiftlyKitError
        }

        guard let assessment = assessmentsByVersion[release.version]
        else { throw SwiftlyKitError.compatibleReleaseUnavailable }

        return assessment
    }

    /// The position of the first compatible assessment.
    public var startIndex: Index {
        assessments.startIndex
    }

    /// The position after the last compatible assessment.
    public var endIndex: Index {
        assessments.endIndex
    }

    /// Returns the position after the specified position.
    public func index(after index: Index) -> Index {
        assessments.index(after: index)
    }

    /// Returns the position before the specified position.
    public func index(before index: Index) -> Index {
        assessments.index(before: index)
    }

    /// Returns the exact compatible assessment at the specified position.
    public subscript(position: Index) -> Element {
        assessments[position]
    }

}

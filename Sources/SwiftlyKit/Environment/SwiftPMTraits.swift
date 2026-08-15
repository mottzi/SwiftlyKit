import Foundation

/// One validated package-trait configuration for a complete SwiftPM workflow.
public struct SwiftPMTraits: Sendable {

    private let configuration: Configuration

    private init(configuration: Configuration) {
        self.configuration = configuration
    }

    /// Creates an explicit trait selection and controls whether package defaults remain enabled.
    /// Names must start with a letter or `_` and can then contain letters, numbers, `_`, `+`, or `-`.
    public init(_ names: [String], includingDefaults: Bool) throws(SwiftlyKitError) {

        for name in names {
            guard Self.isValid(name) else { throw SwiftlyKitError.invalidSwiftPMTrait(name) }
        }

        let names = Array(Set(names)).sorted()
        guard !names.isEmpty else {
            configuration = includingDefaults ? .packageDefaults : .none
            return
        }

        configuration = .selected(names: names, includingDefaults: includingDefaults)
    }

}

extension SwiftPMTraits {

    /// Returns the normalized SwiftPM arguments for this trait configuration.
    var arguments: [String] {
        switch configuration {
            case .packageDefaults:
                []

            case .none:
                ["--disable-default-traits"]

            case .all:
                ["--enable-all-traits"]

            case .selected(let names, let includingDefaults):
                ["--traits", (names + (includingDefaults ? ["default"] : [])).joined(separator: ",")]
        }
    }

}

extension SwiftPMTraits {

    private static func isValid(_ name: String) -> Bool {

        guard let first = name.first else { return false }
        guard first == "_" || first.isLetter else { return false }
        guard name.allSatisfy({ $0 == "_" || $0 == "+" || $0 == "-" || $0.isLetter || $0.isNumber })
        else { return false }

        let normalizedName = name.lowercased()
        return normalizedName != "default" && normalizedName != "defaults"
    }

}

extension SwiftPMTraits {

    /// Normalized package-trait choices used to construct SwiftPM arguments.
    private enum Configuration: Sendable {
        case packageDefaults
        case none
        case all
        case selected(names: [String], includingDefaults: Bool)
    }

}

extension SwiftPMTraits {

    /// Uses the traits that the package enables by default.
    public static let packageDefaults = SwiftPMTraits(configuration: .packageDefaults)

    /// Disables all package traits.
    public static let none = SwiftPMTraits(configuration: .none)

    /// Enables all package traits.
    public static let all = SwiftPMTraits(configuration: .all)

}

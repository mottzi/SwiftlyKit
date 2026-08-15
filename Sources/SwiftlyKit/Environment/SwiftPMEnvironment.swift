import Foundation

/// Caller-controlled SwiftPM process values bound to one prepared Local build environment.
/// SwiftlyKit redacts sensitive values from its output, but trusted manifests, plugins, caches, and tools can use them.
public struct SwiftPMEnvironment: Sendable {

    private let entries: [String: Value]

    /// Creates validated additions, replacements, and removals for SwiftPM processes.
    /// Rejects process values that can replace SwiftlyKit's selected tools, SDK, storage, or host state.
    public init(_ values: [String: Value] = [:]) throws(SwiftlyKitError) {

        for (name, value) in values {
            try Self.validate(name: name, value: value)
        }
        entries = values
    }

    private init(uncheckedEntries: [String: Value]) {
        entries = uncheckedEntries
    }

    /// Captures and resolves one process environment for all SwiftPM operations in a prepared workflow.
    func snapshot(inheriting inherited: [String: String] = ProcessInfo.processInfo.environment) -> Snapshot {

        var toolValues = inherited
        for name in inherited.keys where Self.isRemovedInheritedName(name) {
            toolValues[name] = nil
        }

        var values = toolValues
        var sensitiveNames = Set(Self.credentialNames.filter { values[$0] != nil })
        for (name, entry) in entries {
            switch entry {
                case .plain(let value):
                    values[name] = value
                    if Self.credentialNames.contains(name) { sensitiveNames.insert(name) }

                case .sensitive(let value):
                    values[name] = value
                    sensitiveNames.insert(name)

                case .unset:
                    values[name] = nil
                    sensitiveNames.remove(name)
            }
        }

        for name in Self.credentialNames {
            toolValues[name] = nil
        }

        return Snapshot(
            values: values,
            sensitiveNames: sensitiveNames,
            toolValues: toolValues
        )
    }

}

extension SwiftPMEnvironment {

    /// Uses one snapshot of the inherited process environment without caller changes.
    public static let inherited = SwiftPMEnvironment(uncheckedEntries: [:])

}

extension SwiftPMEnvironment {

    /// One caller instruction for a SwiftPM process value.
    public enum Value: Sendable {

        /// Adds or replaces a nonsecret value.
        case plain(String)

        /// Adds or replaces a value that SwiftlyKit redacts from its output.
        case sensitive(String)

        /// Removes an inherited value.
        case unset

    }

}

extension SwiftPMEnvironment {

    private static func validate(name: String, value: Value) throws(SwiftlyKitError) {

        let validName = name.range(
            of: #"^[A-Za-z_][A-Za-z0-9_]*$"#,
            options: .regularExpression
        ) != nil
        guard validName else { throw .invalidSwiftPMEnvironmentVariable(name) }
        guard !isProtectedName(name) else { throw .invalidSwiftPMEnvironmentVariable(name) }

        switch value {
            case .plain(let value), .sensitive(let value):
                guard !value.contains("\0") else { throw .invalidSwiftPMEnvironmentVariable(name) }

            case .unset:
                break
        }
    }

    private static func isProtectedName(_ name: String) -> Bool {
        preservedInheritedNames.contains(name) || isRemovedInheritedName(name)
    }

    private static func isRemovedInheritedName(_ name: String) -> Bool {
        removedInheritedNames.contains(name)
            || name == "ADDITIONAL_SWIFT_DRIVER_FLAGS"
            || name.hasPrefix("SWIFT_DRIVER_")
    }

}

extension SwiftPMEnvironment {

    /// One resolved process environment and its output-protection metadata.
    struct Snapshot: Sendable {
        let values: [String: String]
        let sensitiveNames: Set<String>
        let toolValues: [String: String]
    }

}

extension SwiftPMEnvironment {

    private static let credentialNames = Set([
        "SWIFTPM_NETRC_DATA",
        "SWIFTPM_REGISTRY_LOGIN",
        "SWIFTPM_REGISTRY_PASSWORD",
        "SWIFTPM_REGISTRY_TOKEN",
        "SWIFTPM_SOURCE_CONTROL_TOKEN"
    ])

    private static let preservedInheritedNames = Set([
        "CFFIXED_USER_HOME",
        "DEVELOPER_DIR",
        "HOME",
        "PATH",
        "SWIFTLY_BIN_DIR",
        "SWIFTLY_HOME",
        "SWIFTLY_HOME_DIR",
        "SWIFTLY_TOOLCHAINS_DIR"
    ])

    private static let removedInheritedNames = Set([
        "AR",
        "CC",
        "CLANG_PATH",
        "CXX",
        "LD",
        "LIBTOOL",
        "SDKROOT",
        "SDK_ROOT",
        "SWIFTPM_CUSTOM_BINDIR",
        "SWIFTPM_CUSTOM_BIN_DIR",
        "SWIFTPM_CUSTOM_LIBS_DIR",
        "SWIFTPM_PD_LIBS",
        "SWIFT_EXEC",
        "SWIFT_EXEC_MANIFEST",
        "TOOLCHAINS",
        "TOOLCHAIN_PATH"
    ])
}

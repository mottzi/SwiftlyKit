import Foundation

/// Exact Swiftly-managed resources that a caller may remove.
public struct EnvironmentRemovalPlan: Codable, Sendable, Hashable {

    /// Receives each complete conservative toolchain or SDK removal plan before
    /// its installation command. A thrown error prevents that command.
    public typealias Recorder = @Sendable (EnvironmentRemovalPlan) async throws -> Void

    let target: Target

    private init(target: Target) {
        self.target = target
    }

    /// Creates a plan for one exact stable Swift toolchain.
    public static func toolchain(_ version: SwiftVersion) -> Self {
        Self(target: .toolchain(version))
    }

    /// Creates a plan for one exact SDK while retaining its toolchain.
    public static func staticLinuxSDK(identifier: String) throws(SwiftlyKitError) -> Self {

        guard isSafeSDKIdentifier(identifier) else {
            throw SwiftlyKitError.unsafeEnvironmentRemoval(
                "The Static Linux SDK identifier is not safe for an exact removal request."
            )
        }
        return Self(target: .staticLinuxSDK(identifier))
    }

    /// Creates a plan for one exact SDK and one exact toolchain.
    public static func environment(
        toolchain: SwiftVersion,
        staticLinuxSDKIdentifier identifier: String
    ) throws(SwiftlyKitError) -> Self {

        guard isSafeSDKIdentifier(identifier) else {
            throw SwiftlyKitError.unsafeEnvironmentRemoval(
                "The Static Linux SDK identifier is not safe for an exact removal request."
            )
        }
        return Self(target: .environment(toolchain: toolchain, identifier: identifier))
    }

}

extension EnvironmentRemovalPlan {

    /// Decodes a versioned exact removal request and validates its SDK identifier.
    public init(from decoder: Decoder) throws {

        let payload = try Payload(from: decoder)
        guard payload.schemaVersion == 1 else {
            throw DecodingError.dataCorruptedError(
                forKey: CodingKeys.schemaVersion,
                in: try decoder.container(keyedBy: CodingKeys.self),
                debugDescription: "Unsupported environment removal plan schema version."
            )
        }

        switch payload.kind {
            case .toolchain:
                guard let toolchain = payload.toolchain, payload.sdkIdentifier == nil else {
                    throw Self.malformedPayload()
                }
                self.init(target: .toolchain(toolchain.value))

            case .staticLinuxSDK:
                guard payload.toolchain == nil, let identifier = payload.sdkIdentifier else {
                    throw Self.malformedPayload()
                }
                guard Self.isSafeSDKIdentifier(identifier) else {
                    throw Self.malformedPayload()
                }
                self.init(target: .staticLinuxSDK(identifier))

            case .environment:
                guard let toolchain = payload.toolchain, let identifier = payload.sdkIdentifier else {
                    throw Self.malformedPayload()
                }
                guard Self.isSafeSDKIdentifier(identifier) else {
                    throw Self.malformedPayload()
                }
                self.init(target: .environment(toolchain: toolchain.value, identifier: identifier))
        }
    }

    /// Encodes this exact removal request as a versioned payload.
    public func encode(to encoder: Encoder) throws {
        try Payload(target: target).encode(to: encoder)
    }

}

extension EnvironmentRemovalPlan {

    private static func isSafeSDKIdentifier(_ identifier: String) -> Bool {

        !identifier.isEmpty
            && !identifier.hasPrefix("-")
            && !identifier.contains("/")
            && !identifier.contains("\\")
            && identifier.unicodeScalars.allSatisfy { (0x21...0x7E).contains($0.value) }
    }

    private static func malformedPayload() -> DecodingError {
        .dataCorrupted(.init(codingPath: [], debugDescription: "Malformed environment removal plan."))
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
    }

    private enum Kind: String, Codable {
        case toolchain
        case staticLinuxSDK
        case environment
    }

    private struct VersionPayload: Codable {
        let major: UInt
        let minor: UInt
        let patch: UInt

        init(_ version: SwiftVersion) {
            major = version.major
            minor = version.minor
            patch = version.patch
        }

        var value: SwiftVersion {
            SwiftVersion(major: major, minor: minor, patch: patch)
        }
    }

    private struct Payload: Codable {
        let schemaVersion: Int
        let kind: Kind
        let toolchain: VersionPayload?
        let sdkIdentifier: String?

        init(target: Target) {
            schemaVersion = 1
            switch target {
                case .toolchain(let version):
                    kind = .toolchain
                    toolchain = VersionPayload(version)
                    sdkIdentifier = nil

                case .staticLinuxSDK(let identifier):
                    kind = .staticLinuxSDK
                    toolchain = nil
                    sdkIdentifier = identifier

                case .environment(let version, let identifier):
                    kind = .environment
                    toolchain = VersionPayload(version)
                    sdkIdentifier = identifier
            }
        }
    }

}

extension EnvironmentRemovalPlan {

    enum Target: Hashable, Sendable {
        case toolchain(SwiftVersion)
        case staticLinuxSDK(String)
        case environment(toolchain: SwiftVersion, identifier: String)
    }

}

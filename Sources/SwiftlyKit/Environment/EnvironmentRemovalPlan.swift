import Foundation

/// Exact toolchain and Static Linux SDK resources that a caller may remove.
public struct EnvironmentRemovalPlan: Codable, Sendable, Hashable {

    /// Receives each complete conservative toolchain or SDK removal plan before
    /// its installation command. A thrown error prevents that command.
    public typealias Recorder = @Sendable (EnvironmentRemovalPlan) async throws -> Void

    let target: Target
    let environmentStorage: EnvironmentStorage

    private init(target: Target, environmentStorage: EnvironmentStorage) {
        self.target = target
        self.environmentStorage = environmentStorage
    }

    /// Creates a plan for one exact stable Swift toolchain.
    public static func toolchain(_ version: SwiftVersion, in storage: EnvironmentStorage = .standard) -> Self {
        Self(target: .toolchain(version), environmentStorage: storage)
    }

    /// Creates a plan for one exact SDK while retaining its toolchain.
    public static func staticLinuxSDK(
        identifier: String,
        in storage: EnvironmentStorage = .standard
    ) throws(SwiftlyKitError) -> Self {

        guard isSafeSDKIdentifier(identifier) else {
            throw SwiftlyKitError.unsafeEnvironmentRemoval(
                "The Static Linux SDK identifier is not safe for an exact removal request."
            )
        }
        return Self(target: .staticLinuxSDK(identifier), environmentStorage: storage)
    }

    /// Creates a plan for one exact SDK and one exact toolchain.
    public static func environment(
        toolchain: SwiftVersion,
        staticLinuxSDKIdentifier identifier: String,
        in storage: EnvironmentStorage = .standard
    ) throws(SwiftlyKitError) -> Self {

        guard isSafeSDKIdentifier(identifier) else {
            throw SwiftlyKitError.unsafeEnvironmentRemoval(
                "The Static Linux SDK identifier is not safe for an exact removal request."
            )
        }
        return Self(
            target: .environment(toolchain: toolchain, identifier: identifier),
            environmentStorage: storage
        )
    }

}

extension EnvironmentRemovalPlan {

    /// Decodes a versioned exact removal request and validates its SDK identifier.
    public init(from decoder: Decoder) throws {

        let payload = try Payload(from: decoder)
        guard payload.schemaVersion == 1 || payload.schemaVersion == 2 else {
            throw DecodingError.dataCorruptedError(
                forKey: CodingKeys.schemaVersion,
                in: try decoder.container(keyedBy: CodingKeys.self),
                debugDescription: "Unsupported environment removal plan schema version."
            )
        }

        let environmentStorage: EnvironmentStorage
        if payload.schemaVersion == 1 {
            environmentStorage = .standard
        } else {
            guard let storagePayload = payload.storage else { throw Self.malformedPayload() }
            environmentStorage = try storagePayload.value()
        }

        switch payload.kind {
            case .toolchain:
                guard let toolchain = payload.toolchain, payload.sdkIdentifier == nil else {
                    throw Self.malformedPayload()
                }
                self.init(target: .toolchain(toolchain.value), environmentStorage: environmentStorage)

            case .staticLinuxSDK:
                guard payload.toolchain == nil, let identifier = payload.sdkIdentifier else {
                    throw Self.malformedPayload()
                }
                guard Self.isSafeSDKIdentifier(identifier) else {
                    throw Self.malformedPayload()
                }
                self.init(target: .staticLinuxSDK(identifier), environmentStorage: environmentStorage)

            case .environment:
                guard let toolchain = payload.toolchain, let identifier = payload.sdkIdentifier else {
                    throw Self.malformedPayload()
                }
                guard Self.isSafeSDKIdentifier(identifier) else {
                    throw Self.malformedPayload()
                }
                self.init(
                    target: .environment(toolchain: toolchain.value, identifier: identifier),
                    environmentStorage: environmentStorage
                )
        }
    }

    /// Encodes this exact removal request as a versioned payload.
    public func encode(to encoder: Encoder) throws {
        try Payload(target: target, environmentStorage: environmentStorage).encode(to: encoder)
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
        let storage: StoragePayload?

        init(target: Target, environmentStorage targetStorage: EnvironmentStorage) {
            schemaVersion = 2
            storage = StoragePayload(targetStorage)
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

    private enum StorageKind: String, Codable {
        case standard
        case directory
    }

    private struct StoragePayload: Codable {
        let kind: StorageKind
        let directory: URL?

        init(_ storage: EnvironmentStorage) {
            switch storage {
                case .standard:
                    kind = .standard
                    directory = nil
                case .directory(let root):
                    kind = .directory
                    directory = root
            }
        }

        func value() throws -> EnvironmentStorage {
            switch kind {
                case .standard:
                    guard directory == nil else { throw EnvironmentRemovalPlan.malformedPayload() }
                    return .standard
                case .directory:
                    guard let directory else { throw EnvironmentRemovalPlan.malformedPayload() }
                    do {
                        _ = try EnvironmentStorage.validatedRoot(directory)
                        return .directory(directory)
                    }
                    catch { throw EnvironmentRemovalPlan.malformedPayload() }
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

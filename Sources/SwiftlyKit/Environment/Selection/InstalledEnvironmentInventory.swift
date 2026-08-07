import Foundation

/// An installed stable Swiftly toolchain that may participate in automatic selection.
struct InstalledStableToolchain: Hashable, Sendable {
    let version: SwiftVersion
}

extension InstalledStableToolchain {
    /// Decodes `swiftly list --format json`, excluding system, snapshot, and malformed entries.
    static func parseSwiftlyList(_ data: Data) throws -> [InstalledStableToolchain] {
        let payload: ToolchainListPayload
        do {
            payload = try JSONDecoder().decode(ToolchainListPayload.self, from: data)
        } catch {
            throw InventoryError.invalidSwiftlyPayload
        }

        return Set(payload.toolchains.compactMap { item in
            guard item.version.type == "stable",
                  let version = SwiftVersion(parsing: item.version.name)
            else { return nil }
            return InstalledStableToolchain(version: version)
        })
        .sorted { $0.version > $1.version }
    }

    private struct ToolchainListPayload: Decodable {
        let toolchains: [ToolchainPayload]
    }

    private struct ToolchainPayload: Decodable {
        let version: VersionPayload
    }

    private struct VersionPayload: Decodable {
        let name: String
        let type: String
    }
}

/// A Static Linux SDK visible through one exact installed Swift toolchain.
struct InstalledStaticLinuxSDK: Hashable, Sendable {
    let toolchainVersion: SwiftVersion
    let identifier: String
}

extension InstalledStaticLinuxSDK {
    /// Parses the line-oriented identifiers emitted by `swift sdk list`.
    static func parseList(
        _ output: String,
        toolchainVersion: SwiftVersion
    ) -> [InstalledStaticLinuxSDK] {
        Set(output.split(whereSeparator: \Character.isNewline).compactMap { line in
            let identifier = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard identifier.contains("_static-linux-"),
                  !identifier.contains(where: \Character.isWhitespace)
            else { return nil }
            return InstalledStaticLinuxSDK(
                toolchainVersion: toolchainVersion,
                identifier: identifier
            )
        })
        .sorted { $0.identifier < $1.identifier }
    }
}

enum InventoryError: Error, Equatable, Sendable {
    case invalidSwiftlyPayload
}

import Darwin
import Foundation

/// Atomic publication of complete runnable output and staged build-storage executable replacement.
enum AtomicOutputPublisher {

    /// Publishes one complete runnable directory without exposing a partial destination.
    static func publish(
        executable: URL,
        executableName: String,
        resourceBundles: [URL],
        architecture: LinuxArchitecture,
        to destination: URL,
        destinationPolicy: DestinationPolicy = .create,
        prepareExecutable: (URL) async throws -> Void = { _ in }
    ) async throws -> BuildResult {

        guard destination.isFileURL,
              executable.isFileURL,
              !executableName.isEmpty,
              URL(filePath: executableName).lastPathComponent == executableName
        else { throw SwiftPMError.outputPublicationFailed(destination) }

        let parent = destination.deletingLastPathComponent()
        let staging = parent.appending(
            path: ".\(destination.lastPathComponent).swiftlykit-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let stagedExecutable = staging.appending(path: executableName)
        var stagingCanBeRemoved = false
        defer {
            if stagingCanBeRemoved {
                try? FileManager.default.removeItem(at: staging)
            }
        }

        do {
            try RuntimeResourceTreeValidator.validateRegularFile(
                executable,
                containedIn: executable.deletingLastPathComponent()
            )
            for bundle in resourceBundles {
                try RuntimeResourceTreeValidator.validateBundle(
                    bundle,
                    in: executable.deletingLastPathComponent()
                )
            }

            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
            stagingCanBeRemoved = true
            try FileManager.default.copyItem(at: executable, to: stagedExecutable)
            for bundle in resourceBundles {
                try FileManager.default.copyItem(
                    at: bundle,
                    to: staging.appending(path: bundle.lastPathComponent, directoryHint: .isDirectory)
                )
            }
        } catch let error as SwiftPMError {
            throw error
        } catch {
            throw SwiftPMError.outputPublicationFailed(destination)
        }

        try await prepareExecutable(stagedExecutable)

        do {
            try validatePublication(
                staging,
                executableName: executableName,
                resourceBundles: resourceBundles
            )
            try publish(
                staging,
                to: destination,
                destinationPolicy: destinationPolicy,
                stagingCanBeRemoved: &stagingCanBeRemoved
            )
        } catch let error as SwiftPMError {
            throw error
        } catch {
            throw SwiftPMError.outputPublicationFailed(destination)
        }

        return BuildResult(
            executable: destination.appending(path: executableName),
            executableName: executableName,
            resourceBundles: resourceBundles.map { bundle in
                destination.appending(path: bundle.lastPathComponent, directoryHint: .isDirectory)
            },
            architecture: architecture
        )
    }

    /// Replaces a SwiftlyKit-owned executable in build storage after staged preparation.
    static func replaceBuildStorageExecutable(
        _ source: URL,
        at destination: URL,
        prepare: (URL) async throws -> Void
    ) async throws -> URL {

        let staging = destination
            .deletingLastPathComponent()
            .appending(path: ".\(destination.lastPathComponent).swiftlykit-\(UUID().uuidString)")
        var stagingCanBeRemoved = false
        defer {
            if stagingCanBeRemoved {
                try? FileManager.default.removeItem(at: staging)
            }
        }

        do {
            try FileManager.default.copyItem(at: source, to: staging)
            stagingCanBeRemoved = true
        } catch {
            throw SwiftPMError.outputPublicationFailed(destination)
        }

        try await prepare(staging)

        do {
            try replace(
                destination,
                with: staging,
                stagingCanBeRemoved: &stagingCanBeRemoved
            )
        } catch let error as SwiftPMError {
            throw error
        } catch {
            throw SwiftPMError.outputPublicationFailed(destination)
        }

        return destination
    }

}

extension AtomicOutputPublisher {

    private static func validatePublication(_ directory: URL, executableName: String, resourceBundles: [URL]) throws {

        let expectedNames = Set([executableName] + resourceBundles.map(\.lastPathComponent))
        let contents = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        guard Set(contents.map(\.lastPathComponent)) == expectedNames
        else { throw SwiftPMError.runtimeResourceVerificationFailed }

        let executable = directory.appending(path: executableName)
        try RuntimeResourceTreeValidator.validateRegularFile(executable, containedIn: directory)

        for bundle in resourceBundles {
            try RuntimeResourceTreeValidator.validateBundle(
                directory.appending(path: bundle.lastPathComponent, directoryHint: .isDirectory),
                in: directory
            )
        }
    }

    private static func publish(
        _ staging: URL,
        to destination: URL,
        destinationPolicy: DestinationPolicy,
        stagingCanBeRemoved: inout Bool
    ) throws {

        switch destinationPolicy {
            case .create:
                try create(
                    staging,
                    at: destination,
                    stagingCanBeRemoved: &stagingCanBeRemoved
                )
            case .replace:
                try replace(
                    destination,
                    with: staging,
                    stagingCanBeRemoved: &stagingCanBeRemoved
                )
            case .existingEmptyDirectory:
                try replaceEmptyDirectory(
                    destination,
                    with: staging,
                    stagingCanBeRemoved: &stagingCanBeRemoved
                )
        }
    }

    private static func create(_ staging: URL, at destination: URL, stagingCanBeRemoved: inout Bool) throws {

        let status = renameatx_np(
            AT_FDCWD,
            staging.path(percentEncoded: false),
            AT_FDCWD,
            destination.path(percentEncoded: false),
            UInt32(RENAME_EXCL)
        )
        if status != 0 && errno == EEXIST { throw SwiftPMError.outputAlreadyExists(destination) }
        guard status == 0 else { throw SwiftPMError.outputPublicationFailed(destination) }
        stagingCanBeRemoved = false
    }

    private static func replace(_ destination: URL, with staging: URL, stagingCanBeRemoved: inout Bool) throws {

        while true {
            if itemExists(at: destination) {
                let status = renameatx_np(
                    AT_FDCWD,
                    staging.path(percentEncoded: false),
                    AT_FDCWD,
                    destination.path(percentEncoded: false),
                    UInt32(RENAME_SWAP)
                )
                if status == 0 {
                    stagingCanBeRemoved = false
                    do {
                        try FileManager.default.removeItem(at: staging)
                    } catch {
                        let rollbackStatus = renameatx_np(
                            AT_FDCWD,
                            staging.path(percentEncoded: false),
                            AT_FDCWD,
                            destination.path(percentEncoded: false),
                            UInt32(RENAME_SWAP)
                        )
                        if rollbackStatus == 0 {
                            stagingCanBeRemoved = true
                        }
                        throw SwiftPMError.outputPublicationFailed(destination)
                    }
                    return
                }
                guard errno == ENOENT else { throw SwiftPMError.outputPublicationFailed(destination) }
            }

            let status = renameatx_np(
                AT_FDCWD,
                staging.path(percentEncoded: false),
                AT_FDCWD,
                destination.path(percentEncoded: false),
                UInt32(RENAME_EXCL)
            )
            if status == 0 {
                stagingCanBeRemoved = false
                return
            }
            guard errno == EEXIST else { throw SwiftPMError.outputPublicationFailed(destination) }
        }
    }

    private static func replaceEmptyDirectory(
        _ destination: URL,
        with staging: URL,
        stagingCanBeRemoved: inout Bool
    ) throws {

        guard rmdir(destination.path(percentEncoded: false)) == 0 else {
            if errno == ENOTEMPTY || errno == EEXIST {
                throw SwiftPMError.outputAlreadyExists(destination)
            }
            throw SwiftPMError.outputPublicationFailed(destination)
        }

        let status = renameatx_np(
            AT_FDCWD,
            staging.path(percentEncoded: false),
            AT_FDCWD,
            destination.path(percentEncoded: false),
            UInt32(RENAME_EXCL)
        )
        guard status == 0 else {
            let failure = errno
            if failure != EEXIST {
                try? FileManager.default.createDirectory(
                    at: destination,
                    withIntermediateDirectories: false
                )
            }
            if failure == EEXIST { throw SwiftPMError.outputAlreadyExists(destination) }
            throw SwiftPMError.outputPublicationFailed(destination)
        }
        stagingCanBeRemoved = false
    }

    private static func itemExists(at url: URL) -> Bool {
        var information = stat()
        return lstat(url.path(percentEncoded: false), &information) == 0
    }

}

extension AtomicOutputPublisher {

    /// Destination mutation allowed when staged output is committed.
    enum DestinationPolicy {
        case create
        case replace
        case existingEmptyDirectory
    }

}

import Darwin
import Foundation

/// Atomic publication of complete runnable output and staged build-storage executable replacement.
enum AtomicOutputPublisher {

    /// Publishes one complete runnable directory without exposing a partial destination.
    static func publish(
        _ output: SwiftPMBuildOutput,
        to destination: URL,
        replacingExisting: Bool = false,
        prepareExecutable: (URL) async throws -> Void = { _ in }
    ) async throws -> BuildResult {

        guard destination.isFileURL,
              output.executable.isFileURL
        else { throw SwiftPMError.outputPublicationFailed(destination) }

        let parent = destination.deletingLastPathComponent()
        let staging = parent.appending(
            path: ".\(destination.lastPathComponent).swiftlykit-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let stagedExecutable = staging.appending(path: output.executable.lastPathComponent)
        defer { try? FileManager.default.removeItem(at: staging) }

        do {
            for bundle in output.resourceBundles {
                try RuntimeResourceTreeValidator.validateBundle(
                    bundle,
                    in: output.executable.deletingLastPathComponent()
                )
            }

            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
            try FileManager.default.copyItem(at: output.executable, to: stagedExecutable)
            for bundle in output.resourceBundles {
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
            try validatePublication(staging, output: output)
            try publish(staging, to: destination, replacingExisting: replacingExisting)
        } catch let error as SwiftPMError {
            throw error
        } catch {
            throw SwiftPMError.outputPublicationFailed(destination)
        }

        return BuildResult(
            executable: destination.appending(path: output.executable.lastPathComponent),
            resourceBundles: output.resourceBundles.map { bundle in
                destination.appending(path: bundle.lastPathComponent, directoryHint: .isDirectory)
            }
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
        defer { try? FileManager.default.removeItem(at: staging) }

        do { try FileManager.default.copyItem(at: source, to: staging) }
        catch {
            throw SwiftPMError.outputPublicationFailed(destination)
        }

        try await prepare(staging)

        do { try replace(destination, with: staging) }
        catch let error as SwiftPMError {
            throw error
        } catch {
            throw SwiftPMError.outputPublicationFailed(destination)
        }

        return destination
    }

}

extension AtomicOutputPublisher {

    private static func validatePublication(_ directory: URL, output: SwiftPMBuildOutput) throws {

        let expectedNames = Set([output.executable.lastPathComponent] + output.resourceBundles.map(\.lastPathComponent))
        let contents = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        guard Set(contents.map(\.lastPathComponent)) == expectedNames
        else { throw SwiftPMError.runtimeResourceVerificationFailed }

        let executable = directory.appending(path: output.executable.lastPathComponent)
        try RuntimeResourceTreeValidator.validateRegularFile(executable, containedIn: directory)

        for bundle in output.resourceBundles {
            try RuntimeResourceTreeValidator.validateBundle(
                directory.appending(path: bundle.lastPathComponent, directoryHint: .isDirectory),
                in: directory
            )
        }
    }

    private static func publish(_ staging: URL, to destination: URL, replacingExisting: Bool) throws {

        guard replacingExisting else {
            let status = renameatx_np(
                AT_FDCWD,
                staging.path(percentEncoded: false),
                AT_FDCWD,
                destination.path(percentEncoded: false),
                UInt32(RENAME_EXCL)
            )
            if status != 0 && errno == EEXIST { throw SwiftPMError.outputAlreadyExists(destination) }
            guard status == 0 else { throw SwiftPMError.outputPublicationFailed(destination) }
            return
        }

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
                    do { try FileManager.default.removeItem(at: staging) }
                    catch {
                        _ = renameatx_np(
                            AT_FDCWD,
                            staging.path(percentEncoded: false),
                            AT_FDCWD,
                            destination.path(percentEncoded: false),
                            UInt32(RENAME_SWAP)
                        )
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
            if status == 0 { return }
            guard errno == EEXIST else { throw SwiftPMError.outputPublicationFailed(destination) }
        }
    }

    private static func replace(_ destination: URL, with staging: URL) throws {

        if itemExists(at: destination) {
            let status = renameatx_np(
                AT_FDCWD,
                staging.path(percentEncoded: false),
                AT_FDCWD,
                destination.path(percentEncoded: false),
                UInt32(RENAME_SWAP)
            )
            guard status == 0 else { throw SwiftPMError.outputPublicationFailed(destination) }
            do { try FileManager.default.removeItem(at: staging) }
            catch {
                _ = renameatx_np(
                    AT_FDCWD,
                    staging.path(percentEncoded: false),
                    AT_FDCWD,
                    destination.path(percentEncoded: false),
                    UInt32(RENAME_SWAP)
                )
                throw SwiftPMError.outputPublicationFailed(destination)
            }
        } else {
            guard renameatx_np(
                AT_FDCWD,
                staging.path(percentEncoded: false),
                AT_FDCWD,
                destination.path(percentEncoded: false),
                UInt32(RENAME_EXCL)
            ) == 0
            else { throw SwiftPMError.outputPublicationFailed(destination) }
        }
    }

    private static func itemExists(at url: URL) -> Bool {
        var information = stat()
        return lstat(url.path(percentEncoded: false), &information) == 0
    }

}

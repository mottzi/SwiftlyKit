import Foundation

enum AtomicOutputCopier {

    static func copy(
        _ source: URL,
        to destination: URL,
        replacingExisting: Bool = false,
        prepare: (URL) async throws -> Void = { _ in }
    ) async throws -> URL {

        guard source.isFileURL,
              destination.isFileURL
        else { throw SwiftPMError.outputCopyFailed(destination) }

        if !replacingExisting {
            guard !FileManager.default.fileExists(atPath: destination.path(percentEncoded: false))
            else { throw SwiftPMError.outputAlreadyExists(destination) }
        }

        let temporary = destination
            .deletingLastPathComponent()
            .appending(path: ".\(destination.lastPathComponent).swiftlykit-\(UUID().uuidString)")

        do { try FileManager.default.copyItem(at: source, to: temporary) }
        catch { throw SwiftPMError.outputCopyFailed(destination) }
        defer { try? FileManager.default.removeItem(at: temporary) }

        try await prepare(temporary)

        let flags = replacingExisting ? 0 : UInt32(RENAME_EXCL)
        let renameStatus = renameatx_np(
            AT_FDCWD,
            temporary.path(percentEncoded: false),
            AT_FDCWD,
            destination.path(percentEncoded: false),
            flags
        )

        if renameStatus != 0 {
            if !replacingExisting && errno == EEXIST { throw SwiftPMError.outputAlreadyExists(destination) }
            throw SwiftPMError.outputCopyFailed(destination)
        }

        return destination
    }

}

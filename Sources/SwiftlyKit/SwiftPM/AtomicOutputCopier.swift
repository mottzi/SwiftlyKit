import Foundation

enum AtomicOutputCopier {

    static func copy(_ source: URL, to destination: URL) throws -> URL {

        guard source.isFileURL,
              destination.isFileURL
        else { throw SwiftPMError.outputCopyFailed(destination) }

        guard !FileManager.default.fileExists(atPath: destination.path)
        else { throw SwiftPMError.outputAlreadyExists(destination) }

        let temporary = destination
            .deletingLastPathComponent()
            .appending(path: ".\(destination.lastPathComponent).swiftlykit-\(UUID().uuidString)")

        do { try FileManager.default.copyItem(at: source, to: temporary) }
        catch { throw SwiftPMError.outputCopyFailed(destination) }
        defer { try? FileManager.default.removeItem(at: temporary) }

        let renameStatus = renameatx_np(AT_FDCWD, temporary.path, AT_FDCWD, destination.path, UInt32(RENAME_EXCL))

        if renameStatus != 0 {
            if errno == EEXIST { throw SwiftPMError.outputAlreadyExists(destination) }
            throw SwiftPMError.outputCopyFailed(destination)
        }

        return destination
    }

}

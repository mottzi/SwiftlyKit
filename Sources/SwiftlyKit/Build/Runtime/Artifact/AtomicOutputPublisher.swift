import Darwin
import Foundation

struct AtomicOutputPublisher: Sendable {
    
    func publish(_ source: URL, to destination: URL) throws -> URL {
        
        guard source.isFileURL, destination.isFileURL else {
            throw BuildRuntimeError.outputPublicationFailed(destination)
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            throw BuildRuntimeError.outputAlreadyExists(destination)
        }
        let temporary = destination.deletingLastPathComponent()
            .appending(path: ".\(destination.lastPathComponent).swiftlykit-\(UUID().uuidString)")
        do {
            try FileManager.default.copyItem(at: source, to: temporary)
        } catch {
            throw BuildRuntimeError.outputPublicationFailed(destination)
        }
        defer { try? FileManager.default.removeItem(at: temporary) }

        let status = renameatx_np(AT_FDCWD, temporary.path, AT_FDCWD, destination.path, UInt32(RENAME_EXCL))
        guard status == 0 else {
            if errno == EEXIST { throw BuildRuntimeError.outputAlreadyExists(destination) }
            throw BuildRuntimeError.outputPublicationFailed(destination)
        }
        return destination
    }
    
}

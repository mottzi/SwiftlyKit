import Darwin
import Foundation

enum AtomicOutputPublisher {
    
    static func publish(_ source: URL, to destination: URL) throws -> URL {
        
        guard source.isFileURL, destination.isFileURL else {
            throw SwiftPMError.outputPublicationFailed(destination)
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            throw SwiftPMError.outputAlreadyExists(destination)
        }
        let temporary = destination.deletingLastPathComponent()
            .appending(path: ".\(destination.lastPathComponent).swiftlykit-\(UUID().uuidString)")
        do {
            try FileManager.default.copyItem(at: source, to: temporary)
        } catch {
            throw SwiftPMError.outputPublicationFailed(destination)
        }
        defer { try? FileManager.default.removeItem(at: temporary) }

        let status = renameatx_np(AT_FDCWD, temporary.path, AT_FDCWD, destination.path, UInt32(RENAME_EXCL))
        guard status == 0 else {
            if errno == EEXIST { throw SwiftPMError.outputAlreadyExists(destination) }
            throw SwiftPMError.outputPublicationFailed(destination)
        }
        return destination
    }
    
}

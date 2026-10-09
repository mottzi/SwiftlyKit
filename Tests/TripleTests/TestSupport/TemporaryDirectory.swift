import Foundation

func withTemporaryDirectory<T>(
    prefix: String,
    _ body: (URL) throws -> T
) throws -> T {

    let directory = FileManager.default.temporaryDirectory
        .appending(path: "\(prefix)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    return try body(directory)
}

func withTemporaryDirectory<T>(
    prefix: String,
    _ body: (URL) async throws -> T
) async throws -> T {

    let directory = FileManager.default.temporaryDirectory
        .appending(path: "\(prefix)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    return try await body(directory)
}

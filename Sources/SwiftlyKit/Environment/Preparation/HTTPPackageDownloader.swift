import Foundation

struct HTTPPackageDownloader {

    private(set) var transfer: @Sendable (URL) async throws -> (temporaryURL: URL, statusCode: Int?) = { source in
        try await HTTPPackageDownloader.liveTransfer(source)
    }

    func download(from source: URL, to destination: URL) async throws {

        guard source.scheme?.lowercased() == "https" else { throw EnvironmentPreparationError.invalidDownloadURL }

        let download = try await transfer(source)

        guard let statusCode = download.statusCode else { throw EnvironmentPreparationError.invalidHTTPResponse(0) }
        guard (200..<300).contains(statusCode)
        else { throw EnvironmentPreparationError.invalidHTTPResponse(statusCode) }

        try FileManager.default.moveItem(at: download.temporaryURL, to: destination)
    }

}

extension HTTPPackageDownloader {

    private static func liveTransfer(_ source: URL) async throws -> (temporaryURL: URL, statusCode: Int?) {

        let (temporaryURL, response) = try await URLSession.shared.download(from: source)

        return (temporaryURL, (response as? HTTPURLResponse)?.statusCode)
    }

}

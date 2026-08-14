import Foundation
import Testing
@testable import SwiftlyKit

@Suite("HTTP package downloader")
struct HTTPPackageDownloaderTests {

    @Test("A non-success response is rejected before publication")
    func rejectsHTTPFailure() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-HTTPPackageDownloader") { temporaryDirectory in
            let source = URL(string: "https://download.swift.org/swiftly.pkg")!
            let temporaryDownload = temporaryDirectory.appending(path: "download")
            let destination = temporaryDirectory.appending(path: "swiftly.pkg")
            try Data("package".utf8).write(to: temporaryDownload)

            let downloader = HTTPPackageDownloader { requestedSource in
                #expect(requestedSource == source)
                return (temporaryDownload, 503)
            }

            await #expect(throws: EnvironmentPreparationError.invalidHTTPResponse(503)) {
                try await downloader.download(from: source, to: destination)
            }

            #expect(!FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)))
        }
    }

}

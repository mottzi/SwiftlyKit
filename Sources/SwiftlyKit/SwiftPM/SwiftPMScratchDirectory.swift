import Foundation

/// A canonical, safety-checked interpretation of a build-storage choice for SwiftPM.
struct SwiftPMScratchDirectory {

    let url: URL
    let isExplicit: Bool

    init(
        storage: BuildStorage,
        packageRoot: URL
    ) throws(SwiftPMError) {

        let configuredURL: URL
        switch storage {
            case .packageDefault:
                configuredURL = packageRoot.appending(path: ".build", directoryHint: .isDirectory)
                isExplicit = false
            case .directory(let directory):
                configuredURL = directory
                isExplicit = true
        }

        let url = configuredURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let packageRoot = packageRoot
            .resolvingSymlinksInPath()
            .standardizedFileURL

        guard !packageRoot.pathComponents.starts(with: url.pathComponents)
        else { throw SwiftPMError.unsafeBuildStorage(url) }

        self.url = url
    }
}

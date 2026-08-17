import Foundation

/// A canonical, safety-checked interpretation of a build-storage choice for SwiftPM.
struct SwiftPMScratchDirectory {

    let url: URL
    let isExplicit: Bool

    init(
        storage: SwiftPMScratchStorage,
        packageRoot: URL,
        sharedStorage: SwiftPMSharedStorage = .standard
    ) throws(SwiftPMError) {

        let configuredURL: URL
        
        switch storage {
            case .packageDefault:
                configuredURL = packageRoot.appending(path: ".build", directoryHint: .isDirectory)
                self.isExplicit = false
            
            case .directory(let directory):
                configuredURL = directory
                self.isExplicit = true
        }

        let url = configuredURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        
        let packageRoot = packageRoot
            .resolvingSymlinksInPath()
            .standardizedFileURL

        guard !packageRoot.pathComponents.starts(with: url.pathComponents)
        else { throw SwiftPMError.unsafeBuildStorage(url) }

        let canonicalURL: URL
        do { canonicalURL = try CanonicalFileURL.resolve(url) }
        catch { throw SwiftPMError.unsafeBuildStorage(url) }

        if let directory = sharedStorage.overlappingDirectory(with: canonicalURL) {
            throw SwiftPMError.unsafeSwiftPMSharedStorage(directory)
        }
        self.url = url
    }
    
}

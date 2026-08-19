import Foundation

/// A canonical, safety-checked interpretation of a build-storage choice for SwiftPM.
struct SwiftPMScratchDirectory {

    let url: URL
    private let isExplicit: Bool

    /// The SwiftPM arguments for an explicitly selected scratch directory.
    var commandArguments: [String] {
        guard isExplicit else { return [] }
        return ["--scratch-path", url.path(percentEncoded: false)]
    }

    init(
        storage: SwiftPMScratchStorage,
        packageRoot: URL,
        sharedStorage: SwiftPMSharedStorage = .standard,
        environmentStorage: EnvironmentStorage = .standard
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

        if case .directory = environmentStorage {
            let location: EnvironmentStorageLocation
            do { location = try environmentStorage.resolved() }
            catch let error {
                if case .unsafeEnvironmentStorage(let url) = error {
                    throw SwiftPMError.unsafeEnvironmentStorage(url)
                }
                throw SwiftPMError.unsafeEnvironmentStorage(url)
            }
            guard !fileURLsOverlap(location.homeDirectory, packageRoot)
            else { throw SwiftPMError.unsafeEnvironmentStorage(location.homeDirectory) }
            guard !fileURLsOverlap(location.homeDirectory, canonicalURL)
            else { throw SwiftPMError.unsafeEnvironmentStorage(location.homeDirectory) }
            guard sharedStorage.overlappingDirectory(with: location.homeDirectory) == nil
            else { throw SwiftPMError.unsafeEnvironmentStorage(location.homeDirectory) }
        }
        self.url = url
    }
    
}

import Foundation

extension SwiftPM {

    func executableProducts(using environment: LocalBuildEnvironment) async throws -> [ExecutableProduct] {
        try await executableProducts(using: environment, scratchStorage: .packageDefault)
    }

    func executableProducts(
        using environment: LocalBuildEnvironment,
        scratchStorage: SwiftPMScratchStorage,
        onEvent: TripleEvent.Handler? = nil
    ) async throws -> [ExecutableProduct] {
        let (products, _) = try await withHostSDK(using: environment, onEvent: onEvent) { candidate in
            let package = try await packageDescription(
                using: candidate,
                scratchStorage: scratchStorage,
                onEvent: onEvent
            )
            return package.products
        }
        return products
    }

}

extension SwiftPM {

    /// Inspects the package with the prepared toolchain without automatic dependency resolution.
    func packageDescription(
        using environment: LocalBuildEnvironment,
        scratchStorage: SwiftPMScratchStorage = .packageDefault,
        onEvent: TripleEvent.Handler? = nil
    ) async throws -> PackageDescription {

        let scratchDirectory = try SwiftPMScratchDirectory(
            storage: scratchStorage,
            packageRoot: environment.packageRoot,
            sharedStorage: environment.swiftPMSharedStorage,
            environmentStorage: environment.environmentStorage
        )

        var arguments = [
            "package",
            "--disable-automatic-resolution"
        ] + environment.swiftPMTraits.arguments + ["dump-package"]
        arguments.insert(contentsOf: scratchDirectory.commandArguments, at: arguments.count - 1)
        let packageCommand = Self.command(
            environment,
            swiftArguments: arguments
        )

        let result = try await runner.run(
            packageCommand,
            onEvent: onEvent,
            forwardingOutput: false
        )

        guard result.succeeded
        else { throw SwiftPMError.commandFailed(operation: .inspectingPackage, diagnostic: Self.boundedDiagnostic(result)) }

        guard let data = result.standardOutput.data(using: .utf8)
        else { throw SwiftPMError.malformedPackageDescription }

        return try PackageDescription(data: data)
    }

}

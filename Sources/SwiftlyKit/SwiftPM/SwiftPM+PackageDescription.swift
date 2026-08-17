import Foundation

extension SwiftPM {

    func executableProducts(using environment: LocalBuildEnvironment) async throws -> [ExecutableProduct] {
        try await executableProducts(using: environment, scratchStorage: .packageDefault)
    }

    func executableProducts(
        using environment: LocalBuildEnvironment,
        scratchStorage: SwiftPMScratchStorage
    ) async throws -> [ExecutableProduct] {
        try validateEnvironment(environment)
        let package = try await packageDescription(using: environment, scratchStorage: scratchStorage)
        return package.products
    }

}

extension SwiftPM {

    func packageDescription(
        using environment: LocalBuildEnvironment,
        scratchStorage: SwiftPMScratchStorage = .packageDefault
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
        if scratchDirectory.isExplicit {
            arguments.insert(contentsOf: [
                "--scratch-path",
                scratchDirectory.url.path(percentEncoded: false)
            ], at: arguments.count - 1)
        }
        let packageCommand = Self.command(
            environment,
            swiftArguments: arguments
        )

        let result = try await runner.run(packageCommand, onOutput: nil)

        guard result.succeeded
        else { throw SwiftPMError.commandFailed(operation: .inspectingPackage, diagnostic: Self.boundedDiagnostic(result)) }

        guard let data = result.standardOutput.data(using: .utf8)
        else { throw SwiftPMError.malformedPackageDescription }

        return try PackageDescription(data: data)
    }

}

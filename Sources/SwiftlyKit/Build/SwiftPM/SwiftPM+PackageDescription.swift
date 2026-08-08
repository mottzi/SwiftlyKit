import Foundation

extension SwiftPM {

    func executableProducts(
        using environment: LocalBuildEnvironment
    ) async throws -> [ExecutableProduct] {
        try validateEnvironment(environment)
        return try await packageDescription(using: environment).products
    }

    func packageDescription(
        using environment: LocalBuildEnvironment
    ) async throws -> SwiftPackageDescription {

        let result = try await runner.run(
            command(
                environment,
                swiftArguments: [
                    "package", "--package-path", environment.packageRoot.path,
                    "--disable-automatic-resolution", "dump-package"
                ],
                workingDirectory: environment.packageRoot
            ),
            onOutput: nil
        )

        guard result.succeeded
        else { throw SwiftPMError.commandFailed(operation: .packageDescription, diagnostic: boundedDiagnostic(result)) }

        guard let data = result.standardOutput.data(using: .utf8) else { throw SwiftPMError.malformedPackageDescription }

        return try SwiftPackageDescription(data: data)
    }

}

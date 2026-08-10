import Foundation

extension SwiftPM {

    func executableProducts(using environment: LocalBuildEnvironment) async throws -> [ExecutableProduct] {
        try validateEnvironment(environment)
        let package = try await packageDescription(using: environment)
        return package.products
    }

    func packageDescription(using environment: LocalBuildEnvironment) async throws -> SwiftPackageDescription {

        let packageCommand = command(
            environment,
            swiftArguments: [
                "package",
                "--disable-automatic-resolution",
                "dump-package"
            ]
        )

        let result = try await runner.run(packageCommand, onOutput: nil)

        guard result.succeeded
        else { throw SwiftPMError.commandFailed(operation: .packageDescription, diagnostic: boundedDiagnostic(result)) }

        guard let data = result.standardOutput.data(using: .utf8)
        else { throw SwiftPMError.malformedPackageDescription }

        return try SwiftPackageDescription(data: data)
    }

}

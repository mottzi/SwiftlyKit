import Foundation

extension SwiftPM {

    func executableProducts(using environment: LocalBuildEnvironment) async throws -> [ExecutableProduct] {
        try validateEnvironment(environment)
        let package = try await packageDescription(using: environment)
        return package.products
    }

}

extension SwiftPM {

    func packageDescription(using environment: LocalBuildEnvironment) async throws -> PackageDescription {

        let arguments = [
            "package",
            "--disable-automatic-resolution"
        ] + environment.swiftPMTraits.arguments + ["dump-package"]
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

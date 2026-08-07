import Foundation

extension SwiftPM {
    
    func executableProducts(
        using environment: LocalBuildEnvironment
    ) async throws -> [ExecutableProduct] {
        try validateEnvironment(environment)
        return try await packageDescription(
            in: environment.packageRoot,
            using: environment.swiftPMEnvironment
        ).products
    }
    
    func packageDescription(
        in packageRoot: URL,
        using environment: SwiftPMEnvironment
    ) async throws -> SwiftPackageDescription {
        
        try validate(environment)
        let result = try await runner.run(
            command(
                environment,
                swiftArguments: [
                    "package", "--package-path", packageRoot.path,
                    "--disable-automatic-resolution", "dump-package"
                ],
                workingDirectory: packageRoot
            ),
            onOutput: nil
        )
        guard result.succeeded else {
            throw SwiftPMError.commandFailed(
                operation: .packageDescription,
                diagnostic: boundedDiagnostic(result)
            )
        }
        guard let data = result.standardOutput.data(using: .utf8) else {
            throw SwiftPMError.malformedPackageDescription
        }
        return try SwiftPackageDescription(data: data)
    }
    
}

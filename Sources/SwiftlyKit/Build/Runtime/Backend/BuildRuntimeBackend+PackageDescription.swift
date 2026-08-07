import Foundation

extension BuildRuntimeBackend {
    
    func executableProducts(
        in packageRoot: URL,
        using environment: BuildRuntimeEnvironment
    ) async throws -> [ExecutableProduct] {
        try await packageDescription(in: packageRoot, using: environment).products
    }
    
    func packageDescription(
        in packageRoot: URL,
        using environment: BuildRuntimeEnvironment
    ) async throws -> BuildRuntimePackageDescription {
        
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
            throw BuildRuntimeError.commandFailed(
                operation: "package description",
                diagnostic: boundedDiagnostic(result)
            )
        }
        guard let data = result.standardOutput.data(using: .utf8) else {
            throw BuildRuntimeError.malformedPackageDescription
        }
        return try BuildRuntimePackageDescription(data: data)
    }
    
}

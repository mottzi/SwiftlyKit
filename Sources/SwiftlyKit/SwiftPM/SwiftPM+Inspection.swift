import Foundation

extension SwiftPM {

    /// Inspects the real package graph, recovering host compilation without changing the Swift selection.
    func inspectPackage(
        using environment: LocalBuildEnvironment,
        scratchStorage: SwiftPMScratchStorage = .packageDefault,
        dependencies: DependencyResolutionPolicy = .requireResolved,
        onEvent: SwiftlyKitEvent.Handler? = nil
    ) async throws -> PackageInspection {

        let (products, selected) = try await withHostSDK(using: environment, onEvent: onEvent) { candidate in
            let package = try await packageDescription(
                using: candidate,
                scratchStorage: scratchStorage,
                onEvent: onEvent
            )
            let scratchDirectory = try SwiftPMScratchDirectory(
                storage: scratchStorage,
                packageRoot: candidate.packageRoot,
                sharedStorage: candidate.swiftPMSharedStorage,
                environmentStorage: candidate.environmentStorage
            )
            do {
                _ = try await sourceRoots(candidate, scratchDirectory, onEvent)
            } catch SwiftPMError.dependencyResolutionRequired {
                guard case .resolveIfNeeded = dependencies else { throw SwiftPMError.dependencyResolutionRequired }
                try await resolveDependenciesDirect(in: scratchStorage, using: candidate, onEvent: onEvent)
                _ = try await sourceRoots(candidate, scratchDirectory, onEvent)
            }
            return ExecutableProducts(package.products)
        }
        return PackageInspection(environment: selected, products: products)
    }

    /// Attempts the bound SDK first, then installed alternatives only for host compiler failures.
    func withHostSDK<Value: Sendable>(
        using environment: LocalBuildEnvironment,
        onEvent: SwiftlyKitEvent.Handler?,
        operation: (LocalBuildEnvironment) async throws -> Value
    ) async throws -> (Value, LocalBuildEnvironment) {

        let environment = try await refreshHostSDK(environment, onEvent: onEvent)
        try validateEnvironment(environment)
        guard let active = environment.hostSDK else { return (try await operation(environment), environment) }
        await report(
            .inspectingPackage,
            detail: "Inspecting package dependencies with Swift \(environment.swiftVersion) "
                + "and macOS SDK \(active.version).",
            to: onEvent
        )
        do {
            return (try await inspectWithFreshCache(environment, operation: operation), environment)
        } catch let error as SwiftPMError {
            guard Self.isHostCompilerFailure(error) else { throw error }
            let alternatives = try hostSDKAlternatives(active)
            var failures = [Self.hostDiagnostic(error, environment: environment)]
            for sdk in alternatives {
                try Task.checkCancellation()
                let candidate = environment.using(hostSDK: sdk)
                await report(
                    .inspectingPackage,
                    detail: "Retrying package inspection with installed macOS SDK \(sdk.version); "
                        + "keeping Swift \(environment.swiftVersion).",
                    to: onEvent
                )
                do {
                    let value = try await inspectWithFreshCache(candidate, operation: operation)
                    await report(
                        .inspectingPackage,
                        detail: "Package dependencies inspected successfully. Using macOS SDK \(sdk.version) "
                            + "with Swift \(environment.swiftVersion).",
                        to: onEvent
                    )
                    return (value, candidate)
                } catch let failure as SwiftPMError {
                    failures.append(Self.hostDiagnostic(failure, environment: candidate))
                    guard Self.isHostCompilerFailure(failure) else { throw failure }
                }
            }
            throw SwiftlyKitError.hostCompilationFailed(
                swiftVersion: environment.swiftVersion,
                detail: failures.joined(separator: "\n\n")
            )
        }
    }

}

extension SwiftPM {

    private func refreshHostSDK(_ environment: LocalBuildEnvironment, onEvent: SwiftlyKitEvent.Handler?)
        async throws -> LocalBuildEnvironment {

        guard let sdk = environment.hostSDK else { return environment }
        do {
            try sdk.validate()
            return environment
        } catch {
            await report(
                .inspectingPackage,
                detail: "Developer tools changed. Reassessing the package with Swift \(environment.swiftVersion).",
                to: onEvent
            )
            let active = try await activeHostSDK(environment.swiftPMEnvironment.toolValues)
            return environment.using(hostSDK: active)
        }
    }

    private func inspectWithFreshCache<Value>(
        _ environment: LocalBuildEnvironment,
        operation: (LocalBuildEnvironment) async throws -> Value
    ) async throws -> Value {

        let directory = FileManager.default.temporaryDirectory.appending(path: "SwiftlyKit-host-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        return try await operation(environment.using(moduleCache: directory))
    }

    private static func isHostCompilerFailure(_ error: SwiftPMError) -> Bool {

        guard case .commandFailed(let operation, let diagnostic) = error else { return false }
        guard operation == .inspectingPackage || operation == .resolvingDependencies else { return false }
        let text = diagnostic.lowercased()
        return text.contains("compile command failed due to signal")
            || text.contains("failed to build module 'foundation'")
            || text.contains("failed to build module 'darwin'")
            || text.contains("sdk is not supported by the compiler")
    }

    private static func hostDiagnostic(_ error: SwiftPMError, environment: LocalBuildEnvironment) -> String {
        let sdk = environment.hostSDK?.directory.path(percentEncoded: false) ?? "unbound"
        return "Swift \(environment.swiftVersion), macOS SDK \(sdk):\n\(error.swiftlyKitError.localizedDescription)"
    }

}

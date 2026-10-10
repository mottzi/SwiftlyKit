import Foundation

extension SwiftPM {

    /// Evaluates only the root manifest for configuration without loading or resolving dependencies.
    func configurePackage(
        using environment: LocalBuildEnvironment,
        scratchStorage: SwiftPMScratchStorage? = nil,
        onEvent: TripleEvent.Handler? = nil
    ) async throws -> PackageConfiguration {

        let storage = scratchStorage ?? .configuration(for: environment.packageRoot)
        let (products, selected) = try await withHostSDK(
            using: environment,
            onEvent: onEvent,
            subject: "the root package manifest"
        ) { candidate in
            let package = try await packageDescription(
                using: candidate,
                scratchStorage: storage,
                onEvent: onEvent
            )
            return ExecutableProducts(package.products)
        }
        return PackageConfiguration(environment: selected, products: products)
    }

    /// Inspects the real package graph, recovering host compilation without changing the Swift selection.
    func inspectPackage(
        using environment: LocalBuildEnvironment,
        scratchStorage: SwiftPMScratchStorage = .packageDefault,
        dependencies: DependencyResolutionPolicy = .requireResolved,
        onEvent: TripleEvent.Handler? = nil
    ) async throws -> PackageInspection {

        let (inspection, selected) = try await withHostSDK(using: environment, onEvent: onEvent) { candidate in
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
            let roots: [URL]
            do {
                roots = try await sourceRoots(candidate, scratchDirectory, onEvent)
            } catch SwiftPMError.dependencyResolutionRequired {
                guard case .resolveIfNeeded = dependencies else { throw SwiftPMError.dependencyResolutionRequired }
                try await resolveDependenciesDirect(in: scratchStorage, using: candidate, onEvent: onEvent)
                roots = try await sourceRoots(candidate, scratchDirectory, onEvent)
            }
            return (ExecutableProducts(package.products), roots)
        }
        return PackageInspection(environment: selected, products: inspection.0, sourceRoots: inspection.1)
    }

    /// Attempts the bound SDK first, then installed alternatives only for host compiler failures.
    func withHostSDK<Value: Sendable>(
        using environment: LocalBuildEnvironment,
        onEvent: TripleEvent.Handler?,
        subject: String = "package dependencies",
        operation: (LocalBuildEnvironment) async throws -> Value
    ) async throws -> (Value, LocalBuildEnvironment) {

        let environment = try await refreshHostSDK(environment, onEvent: onEvent)
        try validateEnvironment(environment)
        guard let active = environment.hostSDK else { return (try await operation(environment), environment) }
        await report(
            .inspectingPackage,
            detail: "Inspecting \(subject) with Swift \(environment.swiftVersion) "
                + "and macOS SDK \(active.version).",
            to: onEvent
        )
        do {
            return (try await operation(environment), environment)
        } catch let error as SwiftPMError {
            guard Self.isHostCompilerFailure(error) else { throw error }
            let alternatives = try hostSDKAlternatives(active)
            var failures = [Self.hostDiagnostic(error, environment: environment)]
            for sdk in alternatives {
                try Task.checkCancellation()
                let candidate = environment.using(hostSDK: sdk)
                await report(
                    .inspectingPackage,
                    detail: "Retrying inspection of \(subject) with installed macOS SDK \(sdk.version); "
                        + "keeping Swift \(environment.swiftVersion).",
                    to: onEvent
                )
                do {
                    let value = try await operation(candidate)
                    await report(
                        .inspectingPackage,
                        detail: "Successfully inspected \(subject). Using macOS SDK \(sdk.version) "
                            + "with Swift \(environment.swiftVersion).",
                        to: onEvent
                    )
                    return (value, candidate)
                } catch let failure as SwiftPMError {
                    failures.append(Self.hostDiagnostic(failure, environment: candidate))
                    guard Self.isHostCompilerFailure(failure) else { throw failure }
                }
            }
            throw TripleError.hostCompilationFailed(
                swiftVersion: environment.swiftVersion,
                detail: failures.joined(separator: "\n\n")
            )
        }
    }

}

extension SwiftPM {

    private func refreshHostSDK(_ environment: LocalBuildEnvironment, onEvent: TripleEvent.Handler?)
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

    private static func isHostCompilerFailure(_ error: SwiftPMError) -> Bool {

        guard case .hostCompilerFailed = error else { return false }
        return true
    }

    private static func hostDiagnostic(_ error: SwiftPMError, environment: LocalBuildEnvironment) -> String {
        let sdk = environment.hostSDK?.directory.path(percentEncoded: false) ?? "unbound"
        return "Swift \(environment.swiftVersion), macOS SDK \(sdk):\n\(error.tripleError.localizedDescription)"
    }

}

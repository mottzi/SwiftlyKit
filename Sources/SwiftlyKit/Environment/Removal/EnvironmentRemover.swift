import Foundation

/// Removes exact Swiftly-managed environment resources after a complete safety preflight.
struct EnvironmentRemover {

    private let temporaryDirectory: URL
    private let runner: any SubprocessRunning
    private let openSession: SessionOpening

    /// Creates a remover using Swiftly's live discovery and subprocess adapters.
    init() {
        let inspector = InstalledEnvironmentInspector()
        self.init(
            temporaryDirectory: FileManager.default.temporaryDirectory,
            runner: LiveSubprocessRunner(),
            openSession: { storage in
                guard let swiftly = try await SwiftlyInstallation.detect(storage: storage)
                else { return nil }

                return EnvironmentRemovalSession(
                    swiftly: swiftly,
                    inspect: { preferredToolchain, includeSDKs in
                        try await inspector.inspectForRemoval(
                            swiftly: swiftly,
                            toolchain: preferredToolchain,
                            includeSDKs: includeSDKs
                        )
                    }
                )
            }
        )
    }

    init(
        temporaryDirectory: URL,
        runner: any SubprocessRunning,
        openSession: @escaping SessionOpening
    ) {
        self.temporaryDirectory = temporaryDirectory
        self.runner = runner
        self.openSession = openSession
    }

    func remove(_ plan: EnvironmentRemovalPlan, onEvent: SwiftlyKitEvent.Handler? = nil) async throws {

        let environmentStorage = plan.environmentStorage
        _ = try environmentStorage.resolved()

        let session: EnvironmentRemovalSession
        do {
            guard let opened = try await openSession(environmentStorage) else {
                throw SwiftlyKitError.incompatibleSwiftly
            }
            session = opened
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SwiftlyKitError {
            throw error
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw SwiftlyKitError.environmentRemovalFailed("Could not detect a compatible Swiftly installation.")
        }

        let swiftly = session.swiftly
        let preferredToolchain = plan.preferredToolchain
        let includeSDKs = plan.requiresSDKState
        var state: EnvironmentRemovalInventory
        do {
            state = try await session.inspect(preferredToolchain, includeSDKs)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SwiftlyKitError {
            throw error
        } catch let error as InstalledEnvironmentError {
            throw SwiftlyKitError.environmentRemovalFailed(Self.inspectionDiagnostic(for: error))
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw SwiftlyKitError.environmentRemovalFailed("Could not inspect Swiftly's installed state.")
        }

        let operations = try preflight(plan, state: state)

        for (index, operation) in operations.enumerated() {
            try Task.checkCancellation()

            if index > 0 {
                let remaining = try preflight(plan, state: state)
                guard !remaining.isEmpty else { continue }
                guard remaining == [operation] else {
                    throw SwiftlyKitError.unsafeEnvironmentRemoval(
                        "Swiftly's installed state changed before the next removal operation."
                    )
                }
            }

            await report(operation, to: onEvent)
            try await run(operation.command(swiftly: swiftly, temporaryDirectory: temporaryDirectory), onEvent: onEvent)

            do {
                state = try await session.inspect(
                    preferredToolchain,
                    operation.requiresSDKState
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                throw SwiftlyKitError.environmentRemovalFailed(
                    "Swiftly's installed state could not be verified after removal."
                )
            }

            if case .sdk = operation {
                do {
                    try requireSDKState(state)
                } catch {
                    throw SwiftlyKitError.environmentRemovalFailed(
                        "Swiftly could not verify the SDK state after removal."
                    )
                }
            }

            guard operation.isAbsent(in: state) else {
                throw SwiftlyKitError.environmentRemovalFailed(
                    "Swiftly still reports the requested resource after removal."
                )
            }
        }
    }

    typealias SessionOpening = @Sendable (
        EnvironmentStorage
    ) async throws -> EnvironmentRemovalSession?

}

extension EnvironmentRemover {

    private func preflight(_ plan: EnvironmentRemovalPlan, state: EnvironmentRemovalInventory) throws -> [Operation] {

        switch plan.target {
            case .toolchain(let version):
                guard let toolchain = state.toolchain(version) else { return [] }
                try requireRemovable(toolchain, version: version)
                return [.toolchain(version)]

            case .staticLinuxSDK(let identifier):
                try requireSDKState(state)
                guard state.contains(sdk: identifier) else { return [] }
                guard let manager = state.sdkManager else {
                    throw SwiftlyKitError.environmentRemovalFailed(
                        "No installed Swift toolchain can inspect the shared SDK registry."
                    )
                }
                return [.sdk(ManagedSDK(identifier: identifier, manager: manager))]

            case .environment(let toolchainVersion, let identifier):
                try requireSDKState(state)
                var operations: [Operation] = []
                if state.contains(sdk: identifier) {
                    guard let manager = state.sdkManager else {
                        throw SwiftlyKitError.environmentRemovalFailed(
                            "No installed Swift toolchain can inspect the shared SDK registry."
                        )
                    }
                    operations.append(.sdk(ManagedSDK(identifier: identifier, manager: manager)))
                }
                if let toolchain = state.toolchain(toolchainVersion) {
                    try requireRemovable(toolchain, version: toolchainVersion)
                    operations.append(.toolchain(toolchainVersion))
                }
                return operations
        }
    }

    private func requireRemovable(_ toolchain: RegisteredToolchain, version: SwiftVersion) throws {

        guard toolchain.selectionStateIsKnown else {
            throw SwiftlyKitError.unsafeEnvironmentRemoval(
                "Swiftly did not report whether Swift \(version) is active or default."
            )
        }
        guard !toolchain.isInUse else {
            throw SwiftlyKitError.unsafeEnvironmentRemoval(
                "Swift " + version.description + " is currently in use and will not be deselected automatically."
            )
        }
        guard !toolchain.isDefault else {
            throw SwiftlyKitError.unsafeEnvironmentRemoval(
                "Swift " + version.description + " is the default toolchain and will not be changed automatically."
            )
        }
    }

    private func requireSDKState(_ state: EnvironmentRemovalInventory) throws {

        switch state.sdkInspection {
            case .available, .absent:
                return
            case .unavailable:
                throw SwiftlyKitError.environmentRemovalFailed(
                    "No installed Swift toolchain can inspect the shared SDK registry."
                )
            case .malformed:
                throw SwiftlyKitError.environmentRemovalFailed(
                    "Swiftly returned malformed shared SDK registry output."
                )
            case .notRequested:
                throw SwiftlyKitError.environmentRemovalFailed(
                    "The shared SDK registry was not inspected."
                )
        }
    }

}

extension EnvironmentRemover {

    private func report(_ operation: Operation, to handler: SwiftlyKitEvent.Handler?) async {

        let detail: String
        switch operation {
            case .sdk(let managedSDK): detail = "Removing Static Linux SDK \(managedSDK.identifier)."
            case .toolchain(let version): detail = "Removing Swift \(version)."
        }
        await handler?(.progress(OperationProgress(operation: .removingEnvironment, detail: detail)))
    }

    private func run(_ command: SubprocessCommand, onEvent: SwiftlyKitEvent.Handler?) async throws {

        let result: SubprocessResult
        do {
            result = try await runner.run(command, onEvent: onEvent)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw SwiftlyKitError.environmentRemovalFailed(
                "Could not run \(command.executableURL.lastPathComponent)."
            )
        }

        guard result.succeeded else {
            throw SwiftlyKitError.environmentRemovalFailed(Self.bounded(result.combinedOutput))
        }
    }

}

extension EnvironmentRemover {

    private static func inspectionDiagnostic(for error: InstalledEnvironmentError) -> String {

        switch error {
            case .commandCouldNotRun(let url): return "Could not inspect Swiftly with \(url.lastPathComponent)."
            case .commandFailed(let detail): return bounded(detail)
            case .invalidOutput: return "Swiftly returned invalid installed-state output."
        }
    }

    private static func bounded(_ value: String) -> String {
        String(value.prefix(8 * 1024))
    }

}

/// One discovered Swiftly installation and its bound inventory observation.
struct EnvironmentRemovalSession: Sendable {

    let swiftly: SwiftlyInstallation
    let inspect: @Sendable (
        SwiftVersion?,
        Bool
    ) async throws -> EnvironmentRemovalInventory

}

extension EnvironmentRemover {

    private enum Operation: Equatable {
        case sdk(ManagedSDK)
        case toolchain(SwiftVersion)

        func command(swiftly: SwiftlyInstallation, temporaryDirectory: URL) -> SubprocessCommand {

            switch self {
                case .sdk(let managedSDK):
                    swiftly.command(
                        tool: "swift",
                        toolchain: managedSDK.manager,
                        arguments: swiftly.sdkCommandArguments([
                            "sdk", "remove", managedSDK.identifier
                        ]),
                        workingDirectory: temporaryDirectory
                    )
                case .toolchain(let version):
                    SubprocessCommand(
                        executableURL: swiftly.executableURL,
                        arguments: ["uninstall", version.description, "--assume-yes"],
                        workingDirectory: temporaryDirectory,
                        environment: swiftly.processEnvironment
                    )
            }
        }

        func isAbsent(in state: EnvironmentRemovalInventory) -> Bool {

            switch self {
                case .sdk(let managedSDK): !state.contains(sdk: managedSDK.identifier)
                case .toolchain(let version): state.toolchain(version) == nil
            }
        }

        var requiresSDKState: Bool {
            switch self {
                case .sdk: return true
                case .toolchain: return false
            }
        }
    }

    private struct ManagedSDK: Equatable {
        let identifier: String
        let manager: SwiftVersion
    }

}

extension EnvironmentRemovalPlan {

    fileprivate var requiresSDKState: Bool {
        switch target {
            case .toolchain: return false
            case .staticLinuxSDK, .environment: return true
        }
    }

    fileprivate var preferredToolchain: SwiftVersion? {
        switch target {
            case .toolchain(let version): return version
            case .staticLinuxSDK: return nil
            case .environment(let version, _): return version
        }
    }

}

import Foundation

/// Thread-safe build source evidence from filesystem events and deterministic snapshots.
final class PackageSourceStability: @unchecked Sendable {

    private let roots: [URL]
    private let excludedRoots: [URL]
    private let initialSnapshot: PackageSourceSnapshot
    private let monitor: PackageSourceMonitor
    private let lock = NSLock()
    private var isFinished = false

    private init(
        roots: [URL],
        excludedRoots: [URL],
        initialSnapshot: PackageSourceSnapshot,
        monitor: PackageSourceMonitor
    ) {
        self.roots = roots
        self.excludedRoots = excludedRoots
        self.initialSnapshot = initialSnapshot
        self.monitor = monitor
    }

    deinit {
        cancel()
    }

    /// Starts observation and captures the initial package-source state.
    static func start(
        roots: [URL],
        excluding excludedRoots: [URL] = []
    ) async throws -> PackageSourceStability {

        let monitor: PackageSourceMonitor
        do { monitor = try PackageSourceMonitor.start(roots: roots, excluding: excludedRoots) }
        catch {
            throw PackageSourceStabilityError.observationFailed(
                "Recursive package-source monitoring could not start."
            )
        }

        do {
            try await monitor.beginObservation()
            let snapshot = try PackageSourceSnapshot.capture(
                roots: roots,
                excluding: excludedRoots
            )
            return PackageSourceStability(
                roots: roots,
                excludedRoots: excludedRoots,
                initialSnapshot: snapshot,
                monitor: monitor
            )
        } catch {
            monitor.cancel()
            if error is CancellationError { throw CancellationError() }
            throw PackageSourceStabilityError.observationFailed(Self.snapshotDiagnostic(error))
        }
    }

    /// Stops observation and rejects changed or incomplete source evidence.
    func finish() async throws {

        guard lock.withLock({
            guard !isFinished else { return false }
            isFinished = true
            return true
        }) else {
            throw PackageSourceStabilityError.observationFailed("Package-source observation already finished.")
        }

        let currentSnapshot: PackageSourceSnapshot
        do {
            currentSnapshot = try PackageSourceSnapshot.capture(
                roots: roots,
                excluding: excludedRoots
            )
        } catch {
            monitor.cancel()
            if error is CancellationError { throw CancellationError() }
            throw PackageSourceStabilityError.observationFailed(Self.snapshotDiagnostic(error))
        }

        let outcome: PackageSourceMonitor.Outcome
        do { outcome = try await monitor.finish() }
        catch {
            monitor.cancel()
            throw error
        }

        switch outcome {
            case .unreliable:
                throw PackageSourceStabilityError.observationFailed(
                    "Recursive package-source monitoring lost filesystem events."
                )
            case .changed:
                throw PackageSourceStabilityError.sourceChanged
            case .unchanged:
                guard currentSnapshot == initialSnapshot
                else { throw PackageSourceStabilityError.sourceChanged }
        }
    }

    /// Stops observation without accepting its source evidence.
    func cancel() {

        let shouldCancel = lock.withLock {
            guard !isFinished else { return false }
            isFinished = true
            return true
        }
        if shouldCancel { monitor.cancel() }
    }

}

extension PackageSourceStability {

    private static func snapshotDiagnostic(_ error: any Swift.Error) -> String {
        switch error {
            case PackageSourceSnapshot.Error.escapingSymbolicLink:
                "A package-source symbolic link resolves outside the observed package roots."
            case PackageSourceSnapshot.Error.missingRoot:
                "The resolved package graph does not contain a source root."
            case PackageSourceSnapshot.Error.sourceTooLarge:
                "The package source exceeds the source-observation limits."
            case PackageSourceSnapshot.Error.unreadableEntry:
                "A package-source root could not be read."
            case PackageSourceSnapshot.Error.unstableEntry:
                "A package-source file changed while SwiftlyKit read it."
            case PackageSourceSnapshot.Error.unsupportedEntry:
                "The package source contains an unsupported filesystem entry."
            default:
                "The package-source state could not be captured."
        }
    }

}

/// Failures that prevent SwiftlyKit from accepting build-time package-source evidence.
enum PackageSourceStabilityError: Swift.Error, Equatable {

    case sourceChanged
    case observationFailed(String)

}

import Foundation
import Testing
@testable import SwiftlyKit

@Suite("SwiftlyKit workflow")
struct SwiftlyKitWorkflowTests {

    @Test("Preparation rejects package inputs changed after assessment")
    func staleAssessment() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-Workflow") { packageRoot in
            let manifestURL = packageRoot.appending(path: "Package.swift")
            let originalManifest = Data("// swift-tools-version: 6.0\n".utf8)
            try originalManifest.write(to: manifestURL)
            let version = SwiftVersion(major: 6, minor: 2, patch: 1)
            let assessment = EnvironmentAssessment(
                packageInputs: try PackageInputSnapshot.capture(at: packageRoot),
                release: OfficialStableRelease(
                    version: version,
                    staticLinuxSDK: StaticLinuxSDK(
                        identifier: "sdk",
                        version: "1.0.0"
                    ),
                    staticLinuxSDKMetadata: StaticLinuxSDKMetadata(
                        downloadURL: URL(string: "https://download.swift.org/sdk.tar.gz")!,
                        checksum: String(repeating: "a", count: 64),
                        supportedArchitectures: [.arm64]
                    )!
                ),
                requiredComponents: [],
                target: .linux(.arm64)
            )
            let kit = SwiftlyKit(
                mutationGate: .shared,
                assessor: EnvironmentAssessor(),
                preparer: EnvironmentPreparer(
                    assessHost: { .ready },
                    detectSwiftly: { Issue.record("detection must follow revalidation"); return nil }
                ),
                swiftPM: SwiftPM(),
                remover: EnvironmentRemover()
            )
            try Data("// swift-tools-version: 6.0\n// changed\n".utf8).write(to: manifestURL)

            await #expect(throws: SwiftlyKitError.staleAssessment) {
                try await kit.prepare(assessment)
            }

            try originalManifest.write(to: manifestURL)
            try Data("6.2.1\n".utf8).write(to: packageRoot.appending(path: ".swift-version"))
            await #expect(throws: SwiftlyKitError.staleAssessment) {
                try await kit.prepare(assessment)
            }
        }
    }

    @Test("The staged public seam propagates recorder errors unchanged")
    func stagedRecorderRefusalIsUnchanged() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-Workflow") { packageRoot in
            try Data("// swift-tools-version: 6.0\n".utf8)
                .write(to: packageRoot.appending(path: "Package.swift"))
            let version = SwiftVersion(major: 6, minor: 2, patch: 1)
            let sdk = StaticLinuxSDK(
                identifier: "swift-6.2.1-RELEASE_static-linux-0.0.1",
                version: "0.0.1"
            )
            let assessment = EnvironmentAssessment(
                packageInputs: try PackageInputSnapshot.capture(at: packageRoot),
                release: OfficialStableRelease(
                    version: version,
                    staticLinuxSDK: sdk,
                    staticLinuxSDKMetadata: StaticLinuxSDKMetadata(
                        downloadURL: URL(string: "https://download.swift.org/sdk.tar.gz")!,
                        checksum: String(repeating: "a", count: 64),
                        supportedArchitectures: [.arm64]
                    )!
                ),
                requiredComponents: [.toolchain],
                target: .linux(.arm64)
            )
            let swiftly = SwiftlyInstallation(executableURL: packageRoot.appending(path: "swiftly"))
            let runner = RecordingSubprocessRunner(results: [.success()])
            let kit = SwiftlyKit(
                mutationGate: .shared,
                assessor: EnvironmentAssessor(),
                preparer: EnvironmentPreparer(
                    runner: runner,
                    assessHost: { .ready },
                    detectSwiftly: { swiftly },
                    inspect: { _, _ in InstalledEnvironmentInventory(toolchains: [], sdks: []) },
                    revalidate: { _ in }
                ),
                swiftPM: SwiftPM(),
                remover: EnvironmentRemover()
            )

            await #expect(throws: WorkflowRecorderRefusal.self) {
                try await kit.prepare(
                    assessment,
                    recordRemovalPlan: { _ in throw WorkflowRecorderRefusal() }
                )
            }
            #expect(await runner.commands.isEmpty)
        }
    }

    @Test("A discovered environment carries package and target context through preparation")
    func capabilityDrivenProductDiscovery() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-Workflow") { packageRoot in
            try Data("// swift-tools-version: 6.0\n".utf8).write(
                to: packageRoot.appending(path: "Package.swift")
            )
            let version = SwiftVersion(major: 6, minor: 2, patch: 1)
            let sdkIdentifier = "swift-6.2.1-RELEASE_static-linux-0.0.1"
            let sdkBundle = packageRoot.appending(path: "\(sdkIdentifier).artifactbundle")
            let swiftly = SwiftlyInstallation(
                executableURL: packageRoot.appending(path: "swiftly")
            )
            let inventory = InstalledEnvironmentInventory(
                toolchains: [version],
                sdks: [InstalledStaticLinuxSDK(
                    toolchainVersion: version,
                    identifier: sdkIdentifier
                )]
            )
            let release = OfficialStableRelease(
                version: version,
                staticLinuxSDK: StaticLinuxSDK(
                    identifier: sdkIdentifier,
                    version: "0.0.1"
                ),
                staticLinuxSDKMetadata: StaticLinuxSDKMetadata(
                    downloadURL: URL(string: "https://download.swift.org/sdk.tar.gz")!,
                    checksum: String(repeating: "a", count: 64),
                    supportedArchitectures: [.arm64]
                )!
            )
            let runner = RecordingSubprocessRunner(results: [
                .success(output: try packageDescriptionJSON(executableProducts: ["Tool"]))
            ])
            let kit = SwiftlyKit(
                mutationGate: .shared,
                assessor: testEnvironmentAssessor(
                    inventory: inventory,
                    isSwiftlyAvailable: true,
                    sdkBundleIdentifiers: [release.staticLinuxSDK.identifier],
                    releaseCatalog: TestAssessmentReleaseCatalog.current([release])
                ),
                preparer: EnvironmentPreparer(
                    runner: runner,
                    assessHost: { .ready },
                    downloadPackage: { _, _ in Issue.record("download must not run") },
                    detectSwiftly: { swiftly },
                    inspect: { _, _ in inventory },
                    locateSDK: { _ in sdkBundle }
                ),
                swiftPM: SwiftPM(
                    testRunner: runner,
                    validateEnvironment: { _ in }
                ),
                remover: EnvironmentRemover()
            )

            let choices = try await kit.compatibleEnvironments(packageRoot, for: .linux(.arm64))
            let assessment = try choices.select(.automatic)
            let environment = try await kit.prepare(assessment)
            let products = try await kit.executableProducts(using: environment)

            #expect(!assessment.requiresInstallation)
            #expect(assessment.isSwiftlyAvailable)
            #expect(assessment.isToolchainAvailable)
            #expect(assessment.isStaticLinuxSDKAvailable)
            #expect(environment.swiftVersion == version)
            #expect(products.map(\.name) == ["Tool"])
        }
    }

    @Test("Staged workflows reuse shared storage and allow a separate resolution scratch directory")
    func stagedStorageIsCapturedAcrossWorkflow() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-Workflow") { packageRoot in
            try Data("// swift-tools-version: 6.0\n".utf8).write(
                to: packageRoot.appending(path: "Package.swift")
            )
            let executable = packageRoot.appending(path: "Tool")
            try writeELF(to: executable, architecture: .arm64)
            let packageJSON = try packageDescriptionJSON(executableProducts: ["Tool"])
            let runner = RecordingSubprocessRunner(results: [
                .success(output: packageJSON),
                .success(output: packageJSON),
                .failure(standardError: "automatic resolution is disabled"),
                .success(output: "resolved"),
                .success(output: packageJSON),
                .success(output: "built"),
                .success(output: packageRoot.path(percentEncoded: false) + "\n")
            ])
            let gate = MutationGate(lockFile: packageRoot.appending(path: "mutation.lock"))
            let kit = convenienceWorkflowKit(packageRoot: packageRoot, gate: gate, runner: runner)
            let cache = packageRoot.appending(path: "cache")
            let configuration = packageRoot.appending(path: "configuration")
            let security = packageRoot.appending(path: "security")
            let sharedStorage = SwiftPMSharedStorage(
                cacheDirectory: cache,
                configurationDirectory: configuration,
                securityDirectory: security
            )
            let scratch = packageRoot.appending(path: "scratch")
            let resolutionScratch = packageRoot.appending(path: "resolution-scratch")

            let assessment = try await kit.assess(packageRoot, for: .linux(.arm64))
            let environment = try await kit.prepare(
                assessment,
                swiftPMSharedStorage: sharedStorage
            )
            let products = try await kit.executableProducts(using: environment)
            let request = BuildRequest(
                try products.select("Tool"),
                scratchStorage: .directory(scratch)
            )

            await #expect(throws: SwiftlyKitError.dependencyResolutionRequired) {
                try await kit.build(request, using: environment)
            }
            try await kit.resolveDependencies(
                in: .directory(resolutionScratch),
                using: environment
            )
            let result = try await kit.build(request, using: environment)

            #expect(result.executable == executable)
            let commands = await runner.commands
            #expect(commands.count == 7)
            for command in commands {
                #expect(
                    normalizedPath(URL(filePath: try argument(after: "--cache-path", in: command.arguments)))
                        == normalizedPath(cache)
                )
                #expect(
                    normalizedPath(URL(filePath: try argument(after: "--config-path", in: command.arguments)))
                        == normalizedPath(configuration)
                )
                #expect(
                    normalizedPath(URL(filePath: try argument(after: "--security-path", in: command.arguments)))
                        == normalizedPath(security)
                )
            }
            #expect(
                normalizedPath(URL(filePath: try argument(after: "--scratch-path", in: commands[2].arguments)))
                    == normalizedPath(scratch)
            )
            #expect(
                normalizedPath(URL(filePath: try argument(after: "--scratch-path", in: commands[3].arguments)))
                    == normalizedPath(resolutionScratch)
            )
            #expect(
                normalizedPath(URL(filePath: try argument(after: "--scratch-path", in: commands[5].arguments)))
                    == normalizedPath(scratch)
            )
            #expect(
                normalizedPath(URL(filePath: try argument(after: "--scratch-path", in: commands[6].arguments)))
                    == normalizedPath(scratch)
            )
        }
    }

    @Test("Independent facades serialize public mutating workflows within one process")
    func mutatingWorkflowsAreSerialized() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-Workflow") { packageRoot in
            let executable = packageRoot.appending(path: "Tool")
            try writeELF(to: executable, architecture: .arm64)
            let runner = WorkflowMutationRunner(binaryDirectory: packageRoot)
            let firstKit = workflowKit(runner: runner)
            let secondKit = workflowKit(runner: runner)
            let environment = LocalBuildEnvironment(
                swiftVersion: SwiftVersion(major: 6, minor: 2, patch: 1),
                staticLinuxSDK: StaticLinuxSDK(
                    identifier: "sdk",
                    version: "1.0.0"
                ),
                packageRoot: packageRoot,
                swiftly: SwiftlyInstallation(executableURL: URL(filePath: "/swiftly")),
                sdkBundleURL: packageRoot.appending(path: "sdk.artifactbundle"),
                target: .linux(.arm64),
                swiftPMEnvironment: SwiftPMEnvironment.inherited.snapshot()
            )

            let resolution = Task {
                try await firstKit.resolveDependencies(in: .packageDefault, using: environment)
            }
            await runner.waitUntilFirstCommandStarts()

            let build = Task {
                try await secondKit.build(
                    BuildRequest(ExecutableProduct(name: "Tool")),
                    using: environment
                )
            }

            let overlapped = await secondCommandStarts(within: .milliseconds(100), runner: runner)
            #expect(!overlapped)

            await runner.releaseCommands()
            try await resolution.value
            let built = try await build.value

            #expect(built.executable == executable)
            #expect(await runner.maximumConcurrentCommands == 1)
        }
    }

    @Test("The convenience API holds one mutation lease for its complete workflow")
    func convenienceMutationLease() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-Workflow") { packageRoot in
            try Data("// swift-tools-version: 6.0\n".utf8).write(
                to: packageRoot.appending(path: "Package.swift")
            )
            let executable = packageRoot.appending(path: "Tool")
            try writeELF(to: executable, architecture: .arm64)
            let runner = WorkflowMutationRunner(binaryDirectory: packageRoot)
            let gate = MutationGate(lockFile: packageRoot.appending(path: "mutation.lock"))
            let kit = convenienceWorkflowKit(packageRoot: packageRoot, gate: gate, runner: runner)
            let environment = workflowEnvironment(packageRoot: packageRoot)

            let convenience = Task {
                try await kit.build(
                    packageRoot,
                    product: "Tool",
                    for: .linux(.arm64),
                    configuration: .release,
                    onEvent: nil
                )
            }
            await runner.waitUntilFirstCommandStarts()

            let resolution = Task {
                try await kit.resolveDependencies(in: .packageDefault, using: environment)
            }

            let overlapped = await secondCommandStarts(within: .milliseconds(100), runner: runner)
            #expect(!overlapped)

            await runner.releaseCommands()
            #expect(try await convenience.value.executable == executable)
            try await resolution.value
            #expect(await runner.maximumConcurrentCommands == 1)
        }
    }

}

private actor WorkflowMutationRunner: SubprocessRunning {

    private(set) var commandCount = 0
    private(set) var maximumConcurrentCommands = 0

    private let binaryDirectory: URL
    private var concurrentCommands = 0
    private var firstCommandWaiters: [CheckedContinuation<Void, Never>] = []
    private var commandsAreReleased = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(binaryDirectory: URL) {
        self.binaryDirectory = binaryDirectory
    }

    func run(_ command: SubprocessCommand, onOutput: SubprocessOutputHandler?) async throws -> SubprocessResult {

        commandCount += 1
        concurrentCommands += 1
        maximumConcurrentCommands = max(maximumConcurrentCommands, concurrentCommands)
        defer { concurrentCommands -= 1 }

        let firstCommandWaiters = self.firstCommandWaiters
        self.firstCommandWaiters.removeAll()
        firstCommandWaiters.forEach { $0.resume() }

        if !commandsAreReleased {
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }

        if command.arguments.contains("dump-package") {
            return .success(output: try packageDescriptionJSON(executableProducts: ["Tool"]))
        }
        if command.arguments.contains("--show-bin-path") {
            return .success(output: binaryDirectory.path(percentEncoded: false) + "\n")
        }

        return .success()
    }

    func waitUntilFirstCommandStarts() async {

        guard commandCount == 0 else { return }
        await withCheckedContinuation { continuation in
            firstCommandWaiters.append(continuation)
        }
    }

    func releaseCommands() {

        commandsAreReleased = true
        let releaseWaiters = self.releaseWaiters
        self.releaseWaiters.removeAll()
        releaseWaiters.forEach { $0.resume() }
    }

}

private func workflowKit(runner: WorkflowMutationRunner) -> SwiftlyKit {

    SwiftlyKit(
        mutationGate: .shared,
        assessor: EnvironmentAssessor(),
        preparer: EnvironmentPreparer(),
        swiftPM: SwiftPM(
            testRunner: runner,
            validateEnvironment: { _ in }
        ),
        remover: EnvironmentRemover()
    )
}

private func convenienceWorkflowKit<Runner: SubprocessRunning>(
    packageRoot: URL,
    gate: MutationGate,
    runner: Runner
) -> SwiftlyKit {

    let version = SwiftVersion(major: 6, minor: 2, patch: 1)
    let swiftly = SwiftlyInstallation(executableURL: packageRoot.appending(path: "swiftly"))
    let sdk = StaticLinuxSDK(
        identifier: "sdk",
        version: "1.0.0"
    )
    let inventory = InstalledEnvironmentInventory(
        toolchains: [version],
        sdks: [InstalledStaticLinuxSDK(toolchainVersion: version, identifier: sdk.identifier)]
    )
    let release = OfficialStableRelease(
        version: version,
        staticLinuxSDK: sdk,
        staticLinuxSDKMetadata: StaticLinuxSDKMetadata(
            downloadURL: URL(string: "https://download.swift.org/sdk.tar.gz")!,
            checksum: String(repeating: "a", count: 64),
            supportedArchitectures: [.arm64]
        )!
    )

    return SwiftlyKit(
        mutationGate: gate,
        assessor: testEnvironmentAssessor(
            inventory: inventory,
            isSwiftlyAvailable: true,
            sdkBundleIdentifiers: [release.staticLinuxSDK.identifier],
            releaseCatalog: TestAssessmentReleaseCatalog.current([release])
        ),
        preparer: EnvironmentPreparer(
            runner: runner,
            assessHost: { .ready },
            downloadPackage: { _, _ in Issue.record("download must not run") },
            detectSwiftly: { swiftly },
            inspect: { _, _ in inventory },
            locateSDK: { _ in packageRoot.appending(path: "sdk.artifactbundle") }
        ),
        swiftPM: SwiftPM(
            testRunner: runner,
            validateEnvironment: { _ in }
        ),
        remover: EnvironmentRemover()
    )
}

private func workflowEnvironment(packageRoot: URL) -> LocalBuildEnvironment {

    LocalBuildEnvironment(
        swiftVersion: SwiftVersion(major: 6, minor: 2, patch: 1),
        staticLinuxSDK: StaticLinuxSDK(
            identifier: "sdk",
            version: "1.0.0"
        ),
        packageRoot: packageRoot,
        swiftly: SwiftlyInstallation(executableURL: packageRoot.appending(path: "swiftly")),
        sdkBundleURL: packageRoot.appending(path: "sdk.artifactbundle"),
        target: .linux(.arm64),
        swiftPMEnvironment: SwiftPMEnvironment.inherited.snapshot(),
        swiftPMSharedStorage: .standard
    )
}

private func secondCommandStarts(within duration: Duration, runner: WorkflowMutationRunner) async -> Bool {

    await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            while !Task.isCancelled {
                if await runner.commandCount >= 2 { return true }
                await Task.yield()
            }
            return false
        }
        group.addTask {
            try? await Task.sleep(for: duration)
            return false
        }

        let result = await group.next() ?? false
        group.cancelAll()
        return result
    }
}

private struct WorkflowRecorderRefusal: Error {

}

private func argument(after option: String, in arguments: [String]) throws -> String {
    let optionIndex = try #require(arguments.firstIndex(of: option))
    return try #require(arguments.dropFirst(optionIndex + 1).first)
}

private func normalizedPath(_ url: URL) -> String {
    let path = url.standardizedFileURL.path(percentEncoded: false)
    let normalized = path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path
    return normalized.hasSuffix("/") ? String(normalized.dropLast()) : normalized
}

# SwiftlyKit

SwiftlyKit cross-compiles a local Swift package on Apple silicon macOS into a
verified, statically linked ARM64 or x86-64 Linux Musl executable. It selects an
official Swift toolchain and matching Static Linux SDK, runs SwiftPM, and returns
the executable with its required resource bundles.

SwiftlyKit is a library for macOS apps and developer tools. If you want a
terminal command, use [SwiftlyKitCLI](https://github.com/mottzi/SwiftlyKitCLI).

## Requirements

- Apple silicon Mac running macOS 13 or later
- Xcode or Command Line Tools with Swift 6.3 or later
- An unsandboxed app or command-line tool
- A trusted local Swift package to build

SwiftlyKit also needs Swiftly 1.0 or later. It can install Swiftly, the selected
toolchain, and the matching SDK when the caller authorizes preparation. It does
not install Xcode or change the active developer directory.

## Installation

In Xcode, select **File > Add Package Dependencies** and enter:

```text
https://github.com/mottzi/SwiftlyKit.git
```

Select version `0.3.1` or later and add the `SwiftlyKit` library to your target.

For a Swift package, add the package and product dependencies:

```swift
// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "YourPackage",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(
            url: "https://github.com/mottzi/SwiftlyKit.git",
            from: "0.3.1"
        )
    ],
    targets: [
        .executableTarget(
            name: "YourTarget",
            dependencies: [
                .product(name: "SwiftlyKit", package: "SwiftlyKit")
            ]
        )
    ]
)
```

## Quick start

Pass the exact package root that contains `Package.swift`:

```swift
import Foundation
import SwiftlyKit

let packageRoot = URL(filePath: "/path/to/package")
let result = try await SwiftlyKit.build(packageRoot)

print(result.executable.path)
```

The default call selects the package's only executable product and builds it for
x86-64 Linux in release mode. It uses the package's `.build` directory, keeps
default package traits, and does not strip the executable.

Select a product, target, or toolchain when the defaults do not fit:

```swift
let result = try await SwiftlyKit.build(
    packageRoot,
    product: "MyTool",
    for: .linux(.arm64),
    toolchain: .exact(SwiftVersion(major: 6, minor: 3, patch: 3)),
    configuration: .debug,
    jobs: 4
)
```

### Publish a runnable directory

Use `.publish` to copy the verified executable and its resource bundles out of
SwiftPM build storage:

```swift
let destination = URL(filePath: "/path/to/output/MyTool")
let result = try await SwiftlyKit.build(
    packageRoot,
    product: "MyTool",
    output: .publish(to: destination),
    strip: true
)
```

The destination's parent directory must exist. SwiftlyKit publishes the complete
directory only after the build, optional stripping, and verification succeed.
It refuses to replace an existing destination unless you pass
`replacingExisting: true`.

Keep `result.executable` and every URL in `result.resourceBundles` together. A
published `result.directory` contains only those runnable files. A result in
SwiftPM build storage can share its directory with unrelated build output.

> [!IMPORTANT]
> `SwiftlyKit.build(_:)` authorizes SwiftlyKit to install missing environment
> components. It may also resolve package dependencies and update
> `Package.resolved`. Use the staged workflow when your app must inspect or
> approve those changes first.

## Choose a workflow

Both workflows use the same build and verification pipeline.

| Workflow | Use it when |
| --- | --- |
| `SwiftlyKit.build(_:)` | One call may prepare the environment, resolve dependencies, and build. |
| Staged API | The caller must inspect requirements, ask for approval, select a product, or control dependency resolution. |

## Staged workflow

A `LocalBuildEnvironment` binds later operations to one package, target,
toolchain, SDK, SwiftPM configuration, and storage selection.

### 1. Assess without changing the system

```swift
let kit = SwiftlyKit()
let assessment = try await kit.assess(
    packageRoot,
    for: .linux(.arm64)
)

print("Swift \(assessment.swiftVersion)")
print("SDK \(assessment.staticLinuxSDK.identifier)")
print("Required components: \(assessment.requiredComponents)")
```

Assessment checks the host and package, then selects an exact official Swift
release and matching SDK. It does not install anything or resolve dependencies.

To present every compatible choice, use one read-only discovery pass:

```swift
let choices = try await kit.compatibleEnvironments(
    packageRoot,
    for: .linux(.arm64)
)
let assessment = try choices.select(.automatic)
```

`EnvironmentChoices` lists each compatible Swift version once, newest first.
The selected version must support the package's `swift-tools-version` and target
architecture.

### 2. Prepare the accepted environment

```swift
let environment = try await kit.prepare(assessment)
```

Call `prepare(_:)` even when `assessment.requiresInstallation` is `false`.
Preparation returns the environment required by later staged operations. If
`Package.swift` or the applicable `.swift-version` file changed after
assessment, assess again.

### 3. Select an executable product

```swift
let products = try await kit.executableProducts(using: environment)
let product = try products.select("MyTool")
```

Pass no name to `select()` only when the package has one executable product.
Product discovery does not resolve dependencies.

### 4. Build

```swift
let scratch = SwiftPMScratchStorage.directory(
    URL(filePath: "/path/to/scratch")
)
let request = BuildRequest(
    product,
    configuration: .release,
    jobs: 4,
    scratchStorage: scratch,
    output: .publish(
        to: URL(filePath: "/path/to/output/MyTool"),
        cleanup: .reset
    ),
    strip: true
)

let result: BuildResult

do {
    result = try await kit.build(request, using: environment)
} catch SwiftlyKitError.dependencyResolutionRequired {
    try await kit.resolveDependencies(in: scratch, using: environment)
    result = try await kit.build(request, using: environment)
}
```

A staged build never resolves dependencies on its own.
`resolveDependencies(in:using:)` can access the network and update
`Package.resolved`.

## Configuration

The convenience call and `BuildRequest` share these build choices:

| Option | Default | Effect |
| --- | --- | --- |
| `product` | `nil` | Selects the only executable product or requires an explicit name. |
| `for` | `.linux(.x86_64)` | Selects ARM64 or x86-64 Linux Musl. |
| `toolchain` | `.automatic` | Selects an official stable Swift toolchain and matching SDK. |
| `configuration` | `.release` | Selects a SwiftPM debug or release build. |
| `jobs` | `nil` | Uses SwiftPM's default concurrency. A positive value sets a limit. |
| `scratchStorage` | `.packageDefault` | Uses `.build` or an explicit SwiftPM scratch directory. |
| `output` | `.buildStorage` | Keeps output in build storage or publishes a runnable directory. |
| `strip` | `false` | Strips a SwiftlyKit-owned copy, then verifies it again. |

The convenience call also accepts SwiftPM environment values, package traits,
shared SwiftPM directories, separate environment storage, a removal-plan
recorder, and an event handler.

### Toolchain selection

`.automatic` selects the first available choice in this order:

1. The compatible official stable version in the nearest `.swift-version` file.
2. The newest compatible installed toolchain and SDK pair.
3. The newest compatible official stable toolchain and SDK pair.

`.exact(SwiftVersion(...))` selects one official stable release. `SwiftVersion`
also accepts `"6.3"` or `"6.3.3"` and normalizes a two-component version to a
patch version of zero. SwiftlyKit does not select snapshots, development
branches, custom SDKs, or arbitrary Swiftly selectors.

### SwiftPM environment and traits

Bind environment values and traits to the complete SwiftPM workflow:

```swift
let values = try SwiftPMEnvironment([
    "PACKAGE_FLAVOR": .plain("production"),
    "SWIFTPM_REGISTRY_TOKEN": .sensitive(token),
    "UNWANTED_PARENT_VALUE": .unset
])
let traits = try SwiftPMTraits(
    ["Production"],
    includingDefaults: true
)

let environment = try await kit.prepare(
    assessment,
    swiftPMEnvironment: values,
    swiftPMTraits: traits
)
```

`.sensitive` values are redacted from events produced by SwiftlyKit. A package
manifest, plugin, cache, or external tool can still read or store them. Keep
long-lived secrets in a credential store.

Use `.packageDefaults`, `.none`, or `.all` for common trait policies.

### Storage and cleanup

| Type | Purpose |
| --- | --- |
| `EnvironmentStorage` | Stores Swiftly, toolchains, and SDKs in standard locations or one caller-owned root. |
| `SwiftPMScratchStorage` | Stores build files and dependency state for one package. |
| `SwiftPMSharedStorage` | Selects SwiftPM cache, configuration, and security directories shared across packages. |

Custom directories must be absolute local paths. An environment root must not
overlap the package, scratch storage, or publication destination. SwiftlyKit can
create a custom environment root but never deletes the root or Swiftly itself.
It ignores inherited `SWIFTLY_*` variables. A custom root does not create a
private `HOME` or move SwiftPM scratch, cache, configuration, or security files.

Publication can run `.retain`, `.clean`, or `.reset` after success. `.clean`
removes compiled output and keeps dependency state. `.reset` removes the complete
effective scratch directory. SwiftlyKit starts cleanup only after it publishes
the runnable directory. If cleanup then fails, SwiftlyKit throws
`postBuildCleanupFailed` and leaves the published directory available.

For cleanup outside a build, use `cleanBuildArtifacts(in:using:)` or
`resetBuildStorage(in:using:)`. Never select a scratch directory that contains
unrelated files.

## Progress and command output

Pass one asynchronous event handler to any mutating operation:

```swift
let onEvent: SwiftlyKitEvent.Handler = { event in
    switch event {
    case .progress(let progress):
        print(progress.detail)

    case .command(let command):
        print(command.executable.path, command.arguments)

    case .output(let output):
        let stream = output.stream == .standardError ? "stderr" : "stdout"
        print("[\(stream)] \(output.text)", terminator: "")

    @unknown default:
        break
    }
}

let environment = try await kit.prepare(
    assessment,
    onEvent: onEvent
)
```

SwiftlyKit awaits the handler for each event and does not retain an event log.
Use `progress.operation` for application state. `progress.detail` and command
details are diagnostic text and can change between releases. Do not start
another mutating SwiftlyKit operation from an event handler.

A command event arrives before SwiftlyKit tries to start that command. Output
events preserve their standard output or standard error stream. A progress event
announces an attempted activity, not its completion. The operation's return or
error is the terminal result. SwiftlyKit reports no percentage when the delegated
tool cannot supply one.

## Verification and runtime output

Before returning a `BuildResult`, SwiftlyKit checks that the executable:

- is a regular executable file
- is a little-endian ELF64 file for the requested architecture
- has a loadable segment
- has no dynamic interpreter
- declares no required dynamic libraries

SwiftlyKit also identifies and validates the product's required `.resources`
directories. Resource trees may contain regular files and directories. They may
not contain links, sockets, devices, FIFOs, or other special entries. The package
and all resolved dependencies must support the selected Linux Musl target.

During compilation, SwiftlyKit monitors the root package and resolved dependency
sources. It withholds the result if relevant files change. This check detects a
change during one build. It does not build from an immutable copy or produce
durable provenance.

Monitoring excludes top-level `.build`, `.git`, and `.swiftpm` directories and
the selected scratch directory. It accepts at most 200,000 files and symbolic
links and 8 GiB of regular-file contents. SwiftlyKit throws
`packageSourceStabilityUnavailable` when it cannot establish or repeat the
observation. Monitoring ends before stripping, publication, and cleanup.

## Host recovery and environment removal

An interactive app can check the host before asking for a package:

```swift
switch try await SwiftlyKit.hostReadiness() {
case .ready:
    break

case .developerToolsUnavailable:
    try await SwiftlyKit.requestCommandLineToolsInstallation()

case .unsupportedHost:
    print("SwiftlyKit requires Apple silicon and macOS 13 or later.")
}
```

The Command Line Tools request returns after macOS accepts it, not after the
installation finishes.

If an app must recover from an interrupted environment installation, pass
`recordRemovalPlan` to `prepare(_:)` or the convenience build. Store the latest
plan before installation starts, then remove its exact resources in a later
operation:

```swift
let environment = try await kit.prepare(
    assessment,
    recordRemovalPlan: { plan in
        try await removalPlanStore.replace(with: plan)
    }
)

let plan = try await removalPlanStore.load()
try await SwiftlyKit.remove(plan)
```

`EnvironmentRemovalPlan` is `Codable`. Removal checks current Swiftly state,
treats an absent target as success, and refuses active or default toolchains.
SwiftlyKit does not store plans or remove installed components automatically.
It awaits the recorder before each toolchain or SDK installation command. If the
recorder throws, that installation does not start. A plan can name a component
that the failed installation never created, so treat it as a recovery request,
not proof of ownership.

## Errors, cancellation, and trust

SwiftlyKit reports operational failures as `SwiftlyKitError`, which conforms to
`LocalizedError`. Handle task cancellation separately:

```swift
do {
    let result = try await SwiftlyKit.build(packageRoot)
    print(result.executable.path)
} catch is CancellationError {
    print("Build cancelled.")
} catch let error as SwiftlyKitError {
    print(error.localizedDescription)
}
```

Errors such as `dependencyResolutionRequired`,
`executableProductSelectionRequired`, `outputAlreadyExists`, and
`staleAssessment` are expected control flow in staged apps. Source, storage,
verification, network, and subprocess failures also use typed error cases.

Other errors that commonly need a distinct response include
`developerToolsUnavailable`, `mutationCoordinationFailed`, `networkFailure`,
`packageChangedDuringBuild`, `packageSourceStabilityUnavailable`,
`postBuildCleanupFailed`, `runtimeResourceVerificationFailed`,
`unsafeBuildStorage`, `unsafeEnvironmentStorage`, `unsafeEnvironmentRemoval`,
and `unsupportedHost`.

Only one preparation, removal, dependency resolution, build, or cleanup runs at
a time for cooperating SwiftlyKit processes owned by one macOS user. Cancel the
calling task to terminate its subprocess group and discard transient publication
files. Direct `swift` and `swiftly` commands do not join this coordination. Do
not use them to modify the same installation, package, storage, SDK, or output
while SwiftlyKit is working. A tool launched by SwiftlyKit can survive if its
parent process ends abruptly. Stop that tool or wait for it before retrying.

SwiftlyKit is not a package sandbox. SwiftPM evaluates `Package.swift` and may
run plugins with the current user's permissions. Build only packages you trust.
SwiftlyKit does not run tests, sign or deploy the executable, modify shell
profiles, select a default toolchain, or keep build history.

## Main types

| Area | Types |
| --- | --- |
| Workflow | `SwiftlyKit`, `EnvironmentChoices`, `EnvironmentAssessment`, `LocalBuildEnvironment` |
| Products and builds | `ExecutableProducts`, `ExecutableProduct`, `BuildRequest`, `BuildResult` |
| Build choices | `BuildOutput`, `BuildCleanup`, `BuildTarget`, `LinuxArchitecture` |
| Toolchains and storage | `ToolchainSelection`, `SwiftVersion`, `EnvironmentStorage`, `SwiftPMScratchStorage`, `SwiftPMSharedStorage` |
| SwiftPM configuration | `SwiftPMEnvironment`, `SwiftPMTraits` |
| Events and recovery | `SwiftlyKitEvent`, `CommandInvocation`, `EnvironmentRemovalPlan`, `SwiftlyKitError` |

## Development

Run the test suite from the repository root:

```sh
swift test
```

Run the real-system acceptance tests on a prepared host:

```sh
SWIFTLYKIT_RUN_ACCEPTANCE=1 swift test --filter AcceptanceTests
```

Acceptance tests never authorize installation. They require compatible Swiftly,
Swift 6.3.3, and its matching Static Linux SDK.

See [Architecture](Documentation/Architecture.md) for the internal design.

## License

SwiftlyKit is available under the MIT License. See [LICENSE](LICENSE).

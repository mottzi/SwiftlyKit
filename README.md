# SwiftlyKit

SwiftlyKit is a macOS library that cross-compiles a trusted local Swift package
into a verified, statically linked Linux executable.

Give SwiftlyKit a package root and select an executable product. SwiftlyKit
selects an official Swift toolchain and its matching Static Linux SDK, builds
the product with SwiftPM, and returns a runnable result with its required
resource bundles.

SwiftlyKit can:

- build for ARM64 or x86-64 Linux Musl from an Apple silicon Mac;
- install Swiftly, the selected toolchain, and its matching SDK when you
  authorize the installation;
- verify that the result is a statically linked ELF64 executable for the
  selected architecture;
- publish the executable and its runtime resources as one complete directory;
  and
- give apps a staged workflow for approval, product selection, progress, build
  settings, storage, and cleanup.

## Requirements

- Apple silicon Mac
- macOS 13 or later
- Swift 6.3 or later for the app or tool that imports SwiftlyKit
- An active macOS SDK from Xcode or Command Line Tools
- An unsandboxed app or command-line tool
- A trusted local Swift package to build

Swiftly 1.0 or later is also required. SwiftlyKit can install Swiftly when you
authorize environment preparation. SwiftlyKit does not install Xcode or select
the active developer directory. It can explicitly request Apple's interactive
Command Line Tools installer.

## Installation

Add SwiftlyKit with Swift Package Manager.

In Xcode, select **File > Add Package Dependencies** and enter:

```text
https://github.com/mottzi/SwiftlyKit.git
```

Select version `0.1.0` or later. Then add the `SwiftlyKit` library to your
target.

For a Swift package, add the package and product dependencies:

```swift
// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "YourPackage",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(
            url: "https://github.com/mottzi/SwiftlyKit.git",
            from: "0.1.0"
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

Import SwiftlyKit and pass the root of a local Swift package to `build(_:)`:

```swift
import Foundation
import SwiftlyKit

let packageRoot = URL(filePath: "/path/to/package")
let result = try await SwiftlyKit.build(packageRoot)

print(result.executable.path)
```

This convenience API:

- selects the package's only executable product;
- targets x86-64 Linux;
- creates a release build with the package's default traits;
- selects the toolchain automatically;
- uses standard environment and SwiftPM workflow storage;
- keeps the executable and its runtime resources in SwiftPM build storage; and
- does not strip the executable.

Specify the product, target, toolchain, or build settings when you need a
different result:

```swift
let result = try await SwiftlyKit.build(
    packageRoot,
    product: "MyTool",
    for: .linux(.arm64),
    toolchain: .exact(SwiftVersion(major: 6, minor: 2, patch: 1)),
    configuration: .debug,
    jobs: 4
)
```

### Publish a runnable directory

Use `.publish` when you need a stable output outside SwiftPM build storage:

```swift
let publicationDirectory = URL(filePath: "/path/to/output/MyTool")
let result = try await SwiftlyKit.build(
    packageRoot,
    product: "MyTool",
    scratchStorage: .directory(URL(filePath: "/path/to/scratch")),
    output: .publish(to: publicationDirectory, cleanup: .reset),
    strip: true
)
```

The executable is now `/path/to/output/MyTool/MyTool`.
`result.resourceBundles` contains the resource bundles that the product needs.
Keep the complete published directory together when you move, upload, or
deploy it.

SwiftlyKit does not replace an existing destination by default. Opt in when a
stable URL must point to the new complete output:

```swift
let result = try await SwiftlyKit.build(
    packageRoot,
    output: .publish(to: publicationDirectory, replacingExisting: true)
)
```

> [!IMPORTANT]
> The convenience API authorizes SwiftlyKit to install Swiftly, the selected
> toolchain, and its SDK when required. It can also resolve dependencies and
> update `Package.resolved`. Use the staged workflow when your app must show or
> approve these changes first.

## Choose a workflow

SwiftlyKit provides two workflows. Both use the same build pipeline.

| Workflow | Use it when |
| --- | --- |
| Convenience API | The caller can authorize the complete operation with one `async` call. |
| Staged workflow | The caller must inspect requirements, ask for approval, select a product, or control dependency resolution. |

The convenience API performs assessment, preparation, product discovery, dependency
resolution when required, and the build. The staged workflow exposes these
operations separately.

## Staged workflow

One `LocalBuildEnvironment` binds the later operations to the assessed package,
target, toolchain, SDK, SwiftPM environment, package traits, and storage choices.

### 1. Assess the environment

Assessment validates the host and package. It selects an exact official Swift
release and matching Static Linux SDK. It does not install components or
resolve package dependencies.

```swift
let kit = SwiftlyKit()
let assessment = try await kit.assess(
    packageRoot,
    for: .linux(.arm64)
)

print("Swift tools version: \(assessment.toolsVersion)")
print("Selected Swift version: \(assessment.swiftVersion)")
print("Selected SDK: \(assessment.staticLinuxSDK.identifier)")

if assessment.requiresInstallation {
    print("Required components: \(assessment.requiredComponents)")
}
```

Use `EnvironmentAssessment` to show the proposed changes to the user. It
reports whether Swiftly, the toolchain, and the SDK are available.

If the user must choose a toolchain, request all compatible environments in one
read-only discovery pass:

```swift
let choices = try await kit.compatibleEnvironments(
    packageRoot,
    for: .linux(.arm64)
)

for choice in choices {
    print("Swift \(choice.swiftVersion): \(choice.requiredComponents)")
}

let selection: ToolchainSelection = .automatic
let assessment = try choices.select(selection)
```

`EnvironmentChoices` lists each compatible environment once, newest first.
`select(_:)` uses the captured results and does not inspect the system again.

### 2. Prepare the environment

Pass the accepted assessment to `prepare(_:)`:

```swift
let environment = try await kit.prepare(assessment)
```

This call authorizes only the items in `requiredComponents`. You must call
`prepare(_:)` even when no installation is required. Later staged operations
need the returned `LocalBuildEnvironment`.

If `Package.swift` or the applicable `.swift-version` file changes after
assessment, preparation throws `SwiftlyKitError.staleAssessment`. Assess the
package again before you continue.

You can bind SwiftPM environment values, package traits, and shared storage at
this step. See [SwiftPM configuration](#swiftpm-configuration).

### 3. Select an executable product

Ask SwiftPM for the executable products in the prepared package:

```swift
let products = try await kit.executableProducts(using: environment)
let product = try products.select("MyTool")
```

Product discovery does not resolve package dependencies. The returned
`ExecutableProducts` value is iterable and indexable. If you call `select()`
without a name, the package must contain exactly one executable product.

### 4. Build the product

Create a `BuildRequest` and use the prepared environment:

```swift
let publicationDirectory = URL(filePath: "/path/to/output/MyTool")
let request = BuildRequest(
    product,
    configuration: .release,
    jobs: 4,
    scratchStorage: .directory(URL(filePath: "/path/to/scratch")),
    output: .publish(to: publicationDirectory, cleanup: .reset),
    strip: true
)

let result: BuildResult

do {
    result = try await kit.build(request, using: environment)
} catch SwiftlyKitError.dependencyResolutionRequired {
    try await kit.resolveDependencies(
        in: request.scratchStorage,
        using: environment
    )
    result = try await kit.build(request, using: environment)
}
```

A staged build never resolves dependencies automatically.
`resolveDependencies(in:using:)` can access the network and update
`Package.resolved`.

SwiftlyKit monitors the root package and its resolved dependencies during
compilation. It withholds the result if relevant package state changes. See
[Source stability](#source-stability) for the scope of this check.

## Build and environment configuration

The defaults support the common convenience build. Use the following options
when the consumer needs more control.

### Build request options

| Option | Default | Behavior |
| --- | --- | --- |
| `configuration` | `.release` | Selects a SwiftPM debug or release build. |
| `jobs` | `nil` | Uses the SwiftPM default. A positive value limits concurrent build jobs. |
| `scratchStorage` | `.packageDefault` | Uses the package `.build` directory. `.directory(URL)` selects an explicit SwiftPM scratch directory. |
| `output` | `.buildStorage` | Returns output in SwiftPM build storage. `.publish(...)` publishes a complete runnable directory. |
| `strip` | `false` | Strips a SwiftlyKit-owned executable with the selected toolchain and verifies it again. |

SwiftlyKit validates `jobs` before it starts a subprocess. Zero and negative
values produce `SwiftlyKitError.invalidBuildJobCount`.

Stripping never changes the executable that SwiftPM produced. With
`.buildStorage`, SwiftlyKit creates a deterministic stripped executable beside
the required resources. With `.publish`, SwiftlyKit strips and verifies only
the staged executable. A strip failure publishes nothing.

The parent of a publication directory must exist. SwiftlyKit publishes only
after stripping and verification succeed. Cleanup starts only after publication
succeeds.

### Toolchain selection

The default `.automatic` policy selects a toolchain in this order:

1. The compatible official stable version in the nearest `.swift-version` file.
2. The newest compatible installed toolchain and matching SDK.
3. The newest compatible official stable toolchain and matching SDK.

The selected version must support the package's `swift-tools-version` and the
requested architecture.

Use `.exact` when the consumer must select one official stable release:

```swift
let result = try await SwiftlyKit.build(
    packageRoot,
    toolchain: .exact(
        SwiftVersion(major: 6, minor: 2, patch: 1)
    )
)
```

Use the lossless text initializer for command-line input or a stored preference:

```swift
if let version = SwiftVersion("6.2.1") {
    let assessment = try choices.select(.exact(version))
    print("Selected Swift \(assessment.swiftVersion).")
}
```

The initializer accepts two or three ASCII decimal components. It normalizes
`"6.2"` to `"6.2.0"`. SwiftlyKit does not use snapshot toolchains, development
branches, custom SDKs, or arbitrary Swiftly selectors.

### Environment storage

SwiftlyKit uses the standard per-user locations for Swiftly, toolchains, and
Static Linux SDKs by default. It ignores inherited `SWIFTLY_*` environment
variables. Select a caller-owned root when the workflow must keep its durable
cross-compilation environment in a separate location:

```swift
let kit = SwiftlyKit(
    environmentStorage: .directory(URL(filePath: "/path/to/environment"))
)
let assessment = try await kit.assess(packageRoot, for: .linux(.arm64))
let environment = try await kit.prepare(assessment)
```

The convenience API accepts the same option:

```swift
let result = try await SwiftlyKit.build(
    packageRoot,
    environmentStorage: .directory(URL(filePath: "/path/to/environment"))
)
```

SwiftlyKit uses `root` for the Swiftly home. It derives `root/bin`,
`root/toolchains`, and `root/swift-sdks` for the Swiftly binary, toolchains, and
SDK registry. The custom root must be an absolute, dedicated local directory.
It must not overlap the package root, SwiftPM workflow storage, or a publication
destination.

SwiftlyKit can create and populate the custom root. It does not delete the root
or remove Swiftly. This option does not create a private `HOME` or isolate
SwiftPM scratch, cache, configuration, or security storage.

### SwiftPM configuration

Bind environment values and package traits during preparation:

```swift
let values = try SwiftPMEnvironment([
    "PACKAGE_FLAVOR": .plain("production"),
    "PKG_CONFIG_PATH": .plain("/opt/linux/lib/pkgconfig"),
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

`SwiftPMTraits.packageDefaults` keeps the package's declared default traits.
Use `.none` to disable all traits, `.all` to enable all traits, or
`SwiftPMTraits(_:includingDefaults:)` to select named traits.

For environment values, `.plain` sets a nonsecret value, `.sensitive` sets a
value that SwiftlyKit redacts from its output, and `.unset` removes an inherited
value. SwiftlyKit also treats known SwiftPM credential variables as sensitive.
It rejects values that could replace the prepared toolchain, SDK, Swiftly
storage, or protected host state.

> [!WARNING]
> SwiftlyKit redacts sensitive values only in output that it returns or streams.
> A trusted manifest, plugin, SwiftPM cache, or external tool can still read or
> store them. Use a credential store for long-lived secrets.

### SwiftPM storage and cleanup

SwiftPM uses scratch storage for one package and shared storage across packages:

| Type | Contents | SwiftlyKit cleanup |
| --- | --- | --- |
| `SwiftPMScratchStorage` | Build files and package dependency state for one package. | `clean` or `reset` can remove files. |
| `SwiftPMSharedStorage` | Cache, configuration, and security files. | SwiftlyKit never removes them. |

Most consumers can use the standard shared directories. A CI job can select a
reusable cache. A host app can select app-owned locations:

```swift
let sharedStorage = SwiftPMSharedStorage(
    cacheDirectory: URL(filePath: "/path/to/swiftpm-cache"),
    configurationDirectory: URL(filePath: "/path/to/swiftpm-configuration"),
    securityDirectory: URL(filePath: "/path/to/swiftpm-security")
)

let environment = try await kit.prepare(
    assessment,
    swiftPMSharedStorage: sharedStorage
)
```

A `nil` shared directory keeps the standard SwiftPM location. The consumer owns
each explicit directory and must coordinate access from multiple processes.

`BuildCleanup.retain` keeps scratch storage and is the default.
`BuildCleanup.clean` runs `swift package clean`. It removes compiled output but
keeps dependency state. `BuildCleanup.reset` runs `swift package reset` and
removes the complete effective scratch directory.

Automatic `.clean` or `.reset` requires the publication directory to be outside
the effective scratch directory. If publication succeeds but cleanup fails,
SwiftlyKit throws `postBuildCleanupFailed`. The published directory remains
available.

Use the staged cleanup operations when cleanup is not part of a build:

```swift
try await kit.cleanBuildArtifacts(
    in: request.scratchStorage,
    using: environment
)

try await kit.resetBuildStorage(
    in: request.scratchStorage,
    using: environment
)
```

Reset removes the complete selected scratch directory. Do not select a directory
that contains unrelated files. SwiftlyKit leaves package sources and
`Package.resolved` unchanged.

### Progress, commands, and output

Pass one event handler to a mutating operation. SwiftlyKit awaits each handler
call and does not keep an event log.

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

Progress events describe preparation, dependency resolution, builds, removal,
stripping, publication, and cleanup. Command events arrive before SwiftlyKit
tries to start each delegated command and before its output. Use them for logs
and diagnostics. SwiftlyKit replaces marked sensitive environment values with
`<redacted>`. Command details can change between SwiftlyKit versions. Output
events contain standard output and standard error from delegated commands.
SwiftlyKit does not report a percentage when the underlying tool cannot supply
a reliable value.

Environment preparation progress contains a semantic component and step. Use
these values for application state and localization. Use `detail` only as
human-readable diagnostic text:

```swift
if case .progress(let progress) = event {
    switch progress.operation {
    case .preparingEnvironment(let component, let step):
        model.currentPreparation = (component, step)

    default:
        model.diagnostic = progress.detail
    }
}
```

A progress event announces an activity before SwiftlyKit attempts it. It does
not report that the activity started or completed. The operation's return or
thrown error reports the terminal outcome.

## Build result and verification

SwiftlyKit supports these Linux Musl targets:

- ARM64: `.linux(.arm64)`
- x86-64: `.linux(.x86_64)`

Before SwiftlyKit returns a `BuildResult`, it checks that the executable:

- is a regular file with executable permissions;
- is a little-endian ELF64 executable for the requested architecture;
- has a loadable segment;
- has no dynamic interpreter; and
- declares no required dynamic libraries.

`BuildResult.executable` is the executable URL. `BuildResult.resourceBundles`
contains the verified `.resources` directories that the selected product needs.
`BuildResult.directory` contains both.

With `.buildStorage`, that directory can also contain output from other SwiftPM
builds. Use `result.resourceBundles` instead of searching the directory. With
`.publish`, the directory contains the executable and its required resource
bundles.

SwiftlyKit rejects missing or ambiguous resource metadata and unsafe resource
trees. Resource trees can contain regular files and directories. They cannot
contain symbolic links, hard links, sockets, devices, FIFOs, or other special
entries.

SwiftPM does not provide a stable interface that lists a product's runtime
resources. SwiftlyKit checks the current link output and generated resource
accessors when the binary directory contains `.resources` candidates. It fails
closed when it cannot identify the required bundles. See
[Architecture](Documentation/Architecture.md) for implementation details.

The package and all its dependencies must support the selected Linux Musl
target.

## Lifecycle and operational behavior

The following sections cover approval recovery, host recovery, and runtime
safety. Most convenience API consumers do not need these interfaces.

### Removal plans

An installation can fail or stop after SwiftlyKit creates a toolchain or SDK.
Supply `recordRemovalPlan` when the consumer must retain an exact removal request
before installation starts:

```swift
let recorder: EnvironmentRemovalPlan.Recorder = { plan in
    try await removalPlanStore.replace(with: plan)
}

let environment = try await kit.prepare(
    assessment,
    recordRemovalPlan: recorder
)
```

The convenience API accepts the same recorder. SwiftlyKit awaits the recorder before
each toolchain or SDK installation command. Store each call as the latest plan.
If the recorder throws, SwiftlyKit does not start that installation command.

A plan can name a resource that the installation did not create. It is a
conservative recovery request, not proof of ownership. SwiftlyKit does not store
plans or remove resources automatically.

Start a fresh operation to remove a stored plan:

```swift
let plan = try await removalPlanStore.load()
try await SwiftlyKit.remove(plan)
```

Removal reads live Swiftly state again. It treats an observable absent target as
success. It refuses active or default toolchains and uninspectable SDK state. A
full environment plan removes the exact SDK before its toolchain.

Plans are `Codable`. You can also create plans for exact known resources:

```swift
let toolchainPlan = EnvironmentRemovalPlan.toolchain(
    SwiftVersion(major: 6, minor: 3, patch: 3)
)

let sdkPlan = try EnvironmentRemovalPlan.staticLinuxSDK(
    identifier: "swift-6.3.3-RELEASE_static-linux-0.1.0"
)
```

Each plan records its `EnvironmentStorage`. Manual factories use `.standard` by
default and accept custom storage with `in:`. A stored plan therefore remains
self-contained.

Inspect a received plan through its semantic resources without decoding its
versioned payload:

```swift
for resource in plan.resources {
    switch resource {
        case .toolchain(let version):
            print("Swift \(version)")

        case .staticLinuxSDK(let identifier):
            print("Static Linux SDK \(identifier)")

        @unknown default:
            break
    }
}

let storage = plan.storage
```

Resource membership does not confirm that installation created a resource or
that the resource still exists. The set does not specify removal order.

### Host readiness

An interactive app can inspect the host before it asks for a package:

```swift
switch try await SwiftlyKit.hostReadiness() {
case .ready:
    print("The host is ready.")

case .developerToolsUnavailable:
    try await SwiftlyKit.requestCommandLineToolsInstallation()
    print("Finish the installation in the macOS dialog, then try again.")

case .unsupportedHost:
    print("SwiftlyKit requires Apple silicon and macOS 13 or later.")
}
```

This check is optional. Assessment and building also check the host.
`requestCommandLineToolsInstallation()` requests Apple's interactive installer
and returns before the installation finishes. It does not install Xcode or
change the active developer directory.

### Catalog availability

SwiftlyKit keeps a validated Swift.org release catalog in memory for one hour.
It also keeps a disposable cache snapshot. During a network failure, SwiftlyKit
can use the snapshot only to select a toolchain and matching SDK that are already
installed. Cached data never authorizes installation.

`compatibleEnvironments(_:for:)` does not use the persistent fallback because a
cached snapshot cannot represent the complete current catalog. The cache
contains only public Swift.org metadata.

### Source stability

During compilation, SwiftlyKit observes the root package and the resolved
dependency graph. It checks paths, file contents, executable permissions, safe
symbolic-link destinations, `Package.swift`, and `Package.resolved`.

SwiftlyKit excludes top-level `.build`, `.git`, and `.swiftpm` directories and
the selected scratch directory. Observation is limited to 200,000 files and
symbolic links and 8 GiB of regular-file contents. If SwiftlyKit cannot establish
or repeat the observation, it throws `packageSourceStabilityUnavailable`.

This check detects changes during compilation. It does not build from an
immutable source copy or create durable build provenance. Observation stops
before stripping, publication, and cleanup.

### Concurrency and cancellation

All long operations are `async throws` functions. Across cooperating SwiftlyKit
processes for one macOS user, only one preparation, removal, dependency
resolution, build, or cleanup operation runs at a time. The convenience API holds
this coordination for its complete workflow. Assessment and product discovery
remain concurrent and read-only.

Do not start another mutating SwiftlyKit operation from an event handler or
removal-plan recorder. SwiftlyKit rejects the operation with
`mutationCoordinationFailed`.

Direct `swift` and `swiftly` commands do not participate in this coordination.
Do not use them to modify the same installation, package, build storage, SDK, or
output while SwiftlyKit is working.

Cancel the calling task to cancel the complete subprocess group. SwiftlyKit
removes transient publication staging directories and throws Swift's standard
`CancellationError`. If a process ends abruptly, a tool that it launched can
survive. Stop that process or wait for it before you retry.

### Environment boundaries

SwiftlyKit does not:

- modify a shell profile or change the default Swift toolchain;
- run `swiftly use`;
- update or replace an existing Swiftly installation;
- remove Swiftly or remove toolchains and SDKs automatically;
- remove scratch storage unless the consumer requests cleanup;
- install Xcode or select Apple developer tools;
- run package tests;
- sign, archive, deploy, or run the Linux executable; or
- keep build history, logs, or artifacts.

SwiftlyKit is not a package sandbox. SwiftPM evaluates `Package.swift` and can
run package plugins with the current user's permissions. Build only packages
that you trust.

### Error handling

SwiftlyKit reports operational failures as `SwiftlyKitError`. This type conforms
to `LocalizedError` and provides a user-facing description. Handle cancellation
separately when the app must show a different status:

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

Common control-flow errors include:

- `dependencyResolutionRequired`
- `developerToolsUnavailable`
- `executableProductSelectionRequired`
- `mutationCoordinationFailed`
- `networkFailure`
- `outputAlreadyExists`
- `packageChangedDuringBuild`
- `packageSourceStabilityUnavailable`
- `postBuildCleanupFailed`
- `runtimeResourceVerificationFailed`
- `staleAssessment`
- `unsafeBuildStorage`
- `unsafeEnvironmentStorage`
- `unsafeEnvironmentRemoval`
- `unsupportedHost`

## Interface overview

| Type | Purpose |
| --- | --- |
| `SwiftlyKit` | Provides host inspection, the convenience API, staged operations, and explicit removal. |
| `EnvironmentChoices`, `EnvironmentAssessment` | Describe compatible environments, the selected environment, and required installations. |
| `LocalBuildEnvironment` | Binds later operations to one prepared package and environment. |
| `ExecutableProducts`, `ExecutableProduct` | List executable products and select one product. |
| `BuildRequest`, `BuildResult` | Describe one build and its verified runnable result. |
| `BuildOutput`, `BuildCleanup` | Control publication and scratch-storage cleanup. |
| `BuildTarget`, `LinuxArchitecture` | Select the Linux Musl architecture. |
| `ToolchainSelection`, `SwiftVersion` | Select an official stable Swift release. |
| `EnvironmentStorage` | Select standard environment storage or one caller-owned root for Swiftly, toolchains, and SDKs. |
| `SwiftPMScratchStorage`, `SwiftPMSharedStorage` | Select SwiftPM workflow storage. |
| `SwiftPMEnvironment`, `SwiftPMTraits` | Configure the complete SwiftPM workflow. |
| `EnvironmentRemovalPlan` | Describe an exact, persistable toolchain or SDK removal request. |
| `SwiftlyKitEvent`, `CommandInvocation` | Report progress, commands, and output. |
| `SwiftlyKitError` | Report typed operational failures. |

## Development

Run the test suite from the repository root:

```sh
swift test
```

Run the real-system acceptance tests on a prepared host:

```sh
SWIFTLYKIT_RUN_ACCEPTANCE=1 swift test --filter AcceptanceTests
```

The traits check runs against the host SwiftPM. The cross-compilation checks
never authorize installation; they require compatible Swiftly, Swift 6.3.3,
and its matching Static Linux SDK. They build and verify both supported
architectures and their published runnable directories.

For the internal design, see [Architecture](Documentation/Architecture.md).

## License

SwiftlyKit is available under the MIT License. See [LICENSE](LICENSE).

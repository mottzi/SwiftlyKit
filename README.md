# Triple

Triple cross-compiles a local Swift package on Apple silicon macOS into a
verified, statically linked ARM64 or x86-64 Linux Musl executable. It selects an
official Swift toolchain and matching Static Linux SDK, runs SwiftPM, and returns
the executable with its required resource bundles.

Triple is a library for macOS apps and developer tools. If you want a
terminal command, use [TripleCLI](https://github.com/mottzi/TripleCLI).

## Requirements

- Apple silicon Mac running macOS 13 or later
- Xcode or Command Line Tools with Swift 6.3 or later
- An unsandboxed app or command-line tool
- A trusted local Swift package to build

Triple also needs Swiftly 1.0 or later. It can install Swiftly, the selected
toolchain, and the matching SDK when the caller authorizes preparation. It does
not install Xcode or change the active developer directory.

Builds use the selected toolchain's default SwiftPM build system. Triple verifies
resources from native link metadata on older toolchains and from the selected
product's Swift Build project model on Swift 6.4.

## Installation

In Xcode, select **File > Add Package Dependencies** and enter:

```text
https://github.com/mottzi/Triple.git
```

The first Triple version is staged as `0.7.0`. Its tag is pending release approval
and publication. The version-based instructions below become usable once the tag
is published.

Select a version requirement starting at `0.7.0` and add the `Triple` library to
your target. This release includes the rebrand, Swift Build resource support,
and cold-cache host SDK recovery.
Existing version tags, including `0.6.0`, export the `SwiftlyKit` module and
cannot satisfy `import Triple`.

For a Swift package, add the package and product dependencies:

```swift
// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "YourPackage",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(
            url: "https://github.com/mottzi/Triple.git",
            from: "0.7.0"
        )
    ],
    targets: [
        .executableTarget(
            name: "YourTarget",
            dependencies: [
                .product(name: "Triple", package: "Triple")
            ]
        )
    ]
)
```

## Migrating from SwiftlyKit

Update the library product and imports to `Triple`, the facade to `Triple`,
and the event and error types to `TripleEvent` and `TripleError`. The CLI command
is `triple`. Swiftly remains the external toolchain manager.

Triple retains the existing `SwiftlyKit` cache and coordination directories.
This preserves cached release metadata during network outages, cached root
manifests, and locking with previously installed clients. Scratch SDK selections
and temporary output names use `.triple`. The internal manifest identity uses
`TRIPLE_HOST_CACHE_CONTEXT`; callers cannot override the old or new key.

## Quick start

Pass the exact package root that contains `Package.swift`:

```swift
import Foundation
import Triple

let packageRoot = URL(filePath: "/path/to/package")
let result = try await Triple.build(packageRoot)

print(result.executable.path)
```

The default call selects the package's only executable product and builds it for
x86-64 Linux in release mode. It uses the package's `.build` directory, keeps
default package traits, and does not strip the executable.

Select a product, target, or toolchain when the defaults do not fit:

```swift
let result = try await Triple.build(
    packageRoot,
    product: "MyTool",
    for: .linux(.arm64),
    toolchain: .exact(SwiftVersion(major: 6, minor: 3, patch: 3)),
    configuration: .debug,
    jobs: 4
)
```

### Export a runnable directory

Use `.export` to copy the verified executable and its resource bundles out of
SwiftPM build storage:

```swift
let destination = URL(filePath: "/path/to/output/MyTool")
let result = try await Triple.build(
    packageRoot,
    product: "MyTool",
    output: .export(to: destination),
    strip: true
)
```

You can also export an existing build result without rebuilding:

```swift
let built = try await Triple.build(packageRoot, product: "MyTool", strip: true)
let result = try await built.export(to: destination)
```

The destination's parent directory must exist. Both paths stage and validate the
complete directory before exporting it. Triple refuses to replace an
existing destination unless you select `policy: .replaceIfPresent`. This policy
also creates the directory when the destination is missing.

To export into an existing empty folder, use the same method with an explicit policy:

```swift
let exported = try await built.export(
    to: destination,
    policy: .requireExistingEmptyDirectory
)
```

The folder must exist and still be empty when Triple commits the export.
Triple preserves its contents if another process adds a file first.

`BuildResult.export` and `BuildOutput.export` share `ExportDestinationPolicy`:

| Policy | Destination rule |
| --- | --- |
| `.createNewDirectory` | The default creates a new directory and rejects any existing destination. |
| `.replaceIfPresent` | Creates a missing directory or replaces the existing destination and its contents. |
| `.requireExistingEmptyDirectory` | Requires an existing empty directory when export commits; does not overwrite contents. |

The destination's parent must exist for every policy. Cleanup is available only
on `BuildOutput.export` and begins after successful export. Exporting a completed
`BuildResult` does not clean build storage and returns a new result identifying
the exported files.

Keep `result.executable` and every URL in `result.resourceBundles` together. An
exported `result.directory` contains only those runnable files. A result in
SwiftPM build storage can share its directory with unrelated build output.
`result.executableName` is the filename used when exporting, even if stripping
changed the filename in build storage.

> [!IMPORTANT]
> `Triple.build(_:)` authorizes Triple to install missing environment
> components and update Swiftly before installing a missing toolchain. It may
> also resolve package dependencies and update `Package.resolved`. Use the staged
> workflow when your app must inspect or approve those changes first.

## Choose a workflow

Both workflows use the same build and verification pipeline.

| Workflow | Use it when |
| --- | --- |
| `Triple.build(_:)` | One call may prepare the environment, resolve dependencies, and build. |
| Staged API | The caller must inspect requirements, ask for approval, select a product, or control dependency resolution. |

## Staged workflow

A `LocalBuildEnvironment` binds later operations to one package, target,
toolchain, SDK, SwiftPM configuration, and storage selection.

### 1. Assess without changing the system

```swift
let kit = Triple()
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

During a catalog outage, both assessment and discovery use validated cached
metadata to reuse complete installed environments. `choices.usesCachedCatalog`
indicates that the list is limited to those environments. Do not replace an
explicit selection just because it is absent from this limited list. New tool
installations and uncached package dependencies still require network access.

### 2. Prepare the accepted environment

```swift
let environment = try await kit.prepare(assessment)
```

When Swiftly is installed but the selected toolchain is missing,
`assessment.requiredComponents` includes `.swiftlyUpdate`. Calling `prepare(_:)`
authorizes checking for and applying a Swiftly update before installing that
toolchain.

Call `prepare(_:)` even when `assessment.requiresInstallation` is `false`.
Preparation returns the environment required by later staged operations. If
`Package.swift` or the applicable `.swift-version` file changed after
assessment, assess again.

### 3. Select an executable product

```swift
let configuration = try await kit.configurePackage(using: environment)
let product = try configuration.products.select("MyTool")
```

Pass no name to `select()` only when the package has one executable product.
Configuration evaluates only the root manifest and does not resolve dependencies.
Use `configuration.environment` for the build to retain any root SDK recovery.

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
    output: .export(
        to: URL(filePath: "/path/to/output/MyTool"),
        cleanup: .reset
    ),
    strip: true
)

let result = try await kit.build(
    request,
    using: configuration.environment,
    dependencies: .resolveIfNeeded
)
```

A staged build defaults to requiring existing resolved dependencies. The explicit
`.resolveIfNeeded` policy authorizes resolution within the same build operation.
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
| `output` | `.buildStorage` | Keeps output in build storage or exports a runnable directory. |
| `strip` | `false` | Strips a Triple-owned copy, then verifies it again. |

Use `BuildTarget.allCases`, `LinuxArchitecture.allCases`, and
`BuildConfiguration.allCases` to list supported choices in your app.

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
patch version of zero. Triple does not select snapshots, development
branches, custom SDKs, or arbitrary Swiftly selectors.

Release eligibility covers the package's Swift tools version and Linux target
architecture. Preparation also captures the active macOS SDK and developer tools
for host manifests, plugins, and macros. `inspectPackage(using:)` evaluates the
root and dependency manifests before returning products and a bound environment.
If host compilation fails, it tries other installed macOS SDK contexts with the
same Swift compiler. Manifest caching includes an identity of the installed
compiler binaries, manifest library, SDK paths, and SDK metadata. Replaced
compiler or SDK contexts cannot reuse a prior context's manifest results.
If that identity cannot be inspected, manifest caching stays disabled. The
compiler's module cache is retained. SDK versions order attempts but never
declare compatibility.

`configurePackage(using:)` evaluates only the root manifest and returns products
with the environment that succeeded. It uses separate stable scratch storage
under the user's cache directory, so configuration can proceed during another
build. Its result does not establish dependency readiness. Builds always evaluate
the full dependency graph before compilation and reuse that graph only within
the same build operation. Pass `dependencies: .resolveIfNeeded` to a staged build
to authorize resolution when required.

```swift
let inspection = try await kit.inspectPackage(
    using: environment,
    dependencies: .resolveIfNeeded
)
let product = try inspection.products.select("MyServer")
let result = try await kit.build(BuildRequest(product), using: inspection.environment)
```

Inspection defaults to `.requireResolved`; `.resolveIfNeeded` explicitly permits
dependency resolution. `environment.hostSDKVersion` reports the selected host SDK.
Subsequent operations bind that SDK per process and reassess removed or replaced
SDKs through fresh package inspection. Triple never changes the global `xcode-select` setting.

When no installed host context can inspect the package, unpinned Automatic can
advance to a newer assessed official Swift release and matching Linux SDK.
Staged callers use `choices.recoveryAssessment(after:for:)` and accept its
installation requirements before preparation. Exact Swift selections and
`.swift-version` pins remain authoritative. Ordinary manifest errors and network
failures do not trigger environment recovery. Inspection establishes manifest
readiness; plugins, macros, and application compilation can still fail later.

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

`.sensitive` values are redacted from events produced by Triple. A package
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
overlap the package, scratch storage, or export destination. Triple can
create a custom environment root but never deletes the root or Swiftly itself.
It ignores inherited `SWIFTLY_*` variables. A custom root does not create a
private `HOME` or move SwiftPM scratch, cache, configuration, or security files.

`BuildOutput.export` accepts `.retain`, `.clean`, or `.reset` for cleanup. `.clean`
removes compiled output and keeps dependency state. `.reset` removes the complete
effective scratch directory. Triple starts cleanup only after it exports
the runnable directory. If cleanup then fails, Triple throws
`postBuildCleanupFailed` and leaves the exported directory available.

For cleanup outside a build, use `cleanBuildArtifacts(in:using:)` or
`resetBuildStorage(in:using:)`. Never select a scratch directory that contains
unrelated files.

## Progress and command output

Pass one asynchronous event handler to any mutating operation:

```swift
let onEvent: TripleEvent.Handler = { event in
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

Triple awaits the handler for each event and does not retain an event log.
Use `progress.operation` for application state. `progress.detail` and command
details are diagnostic text and can change between releases. Do not start
another mutating Triple operation from an event handler.

A command event arrives before Triple tries to start that command. Output
events preserve their standard output or standard error stream. A progress event
announces an attempted activity, not its completion. The operation's return or
error is the terminal result. Triple reports no percentage when the delegated
tool cannot supply one.

## Verification and runtime output

Before returning a `BuildResult`, Triple checks that the executable:

- is a regular executable file
- is a little-endian ELF64 file for the requested architecture
- has a loadable segment
- has no dynamic interpreter
- declares no required dynamic libraries

Triple also identifies and validates the product's required `.resources`
directories. Resource trees may contain regular files and directories. They may
not contain links, sockets, devices, FIFOs, or other special entries. A verified
bundle containing only the regular file `PrivacyInfo.xcprivacy` is omitted from
`BuildResult.resourceBundles` and exports. SwiftPM can still produce that bundle
in build storage. Bundles containing other resources remain part of the result.
The package and all resolved dependencies must support the selected Linux Musl target.

During compilation, Triple monitors the root package and resolved dependency
sources. It withholds the result if relevant files change. This check detects a
change during one build. It does not build from an immutable copy or produce
durable provenance.

Monitoring excludes top-level `.build`, `.git`, and `.swiftpm` directories and
the selected scratch directory. It accepts at most 200,000 files and symbolic
links and 8 GiB of regular-file contents. Triple throws
`packageSourceStabilityUnavailable` when it cannot establish or repeat the
observation. Monitoring ends before stripping, export, and cleanup.

## Host recovery and environment removal

An interactive app can check the host before asking for a package:

```swift
switch try await Triple.hostReadiness() {
case .ready:
    break

case .developerToolsUnavailable:
    try await Triple.requestCommandLineToolsInstallation()

case .unsupportedHost:
    print("Triple requires Apple silicon and macOS 13 or later.")
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
try await Triple.remove(plan)
```

`EnvironmentRemovalPlan` is `Codable`. Removal checks current Swiftly state,
treats an absent target as success, and refuses active or default toolchains.
Triple does not store plans or remove installed components automatically.
It awaits the recorder before each toolchain or SDK installation command. If the
recorder throws, that installation does not start. A plan can name a component
that the failed installation never created, so treat it as a recovery request,
not proof of ownership.

## Errors, cancellation, and trust

Triple reports operational failures as `TripleError`, which conforms to
`LocalizedError`. Handle task cancellation separately:

```swift
do {
    let result = try await Triple.build(packageRoot)
    print(result.executable.path)
} catch is CancellationError {
    print("Build cancelled.")
} catch let error as TripleError {
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

Only one preparation, removal, dependency resolution, build, export, or
cleanup runs at a time for cooperating Triple processes owned by one macOS
user. Cancel the calling task to terminate its subprocess group and discard
transient export files. Direct `swift` and `swiftly` commands do not join
this coordination. Do not use them to modify the same installation, package, storage, SDK, or output
while Triple is working. A tool launched by Triple can survive if its
parent process ends abruptly. Stop that tool or wait for it before retrying.

Triple is not a package sandbox. SwiftPM evaluates `Package.swift` and may
run plugins with the current user's permissions. Build only packages you trust.
Triple does not run tests, sign or deploy the executable, modify shell
profiles, select a default toolchain, or keep build history.

## Main types

| Area | Types |
| --- | --- |
| Workflow | `Triple`, `EnvironmentChoices`, `EnvironmentAssessment`, `LocalBuildEnvironment` |
| Products and builds | `ExecutableProducts`, `ExecutableProduct`, `BuildRequest`, `BuildResult` |
| Build choices | `BuildOutput`, `BuildCleanup`, `BuildTarget`, `LinuxArchitecture` |
| Toolchains and storage | `ToolchainSelection`, `SwiftVersion`, `EnvironmentStorage`, `SwiftPMScratchStorage`, `SwiftPMSharedStorage` |
| SwiftPM configuration | `SwiftPMEnvironment`, `SwiftPMTraits` |
| Events and recovery | `TripleEvent`, `CommandInvocation`, `EnvironmentRemovalPlan`, `TripleError` |

## Development

Run the test suite from the repository root:

```sh
swift test
```

Run the real-system acceptance tests on a prepared host:

```sh
TRIPLE_RUN_ACCEPTANCE=1 swift test --filter AcceptanceTests
```

Acceptance tests never authorize installation. They require compatible Swiftly,
Swift 6.3.3, and its matching Static Linux SDK.

See [Architecture](Documentation/Architecture.md) for the internal design.

## License

Triple is available under the MIT License. See [LICENSE](LICENSE).

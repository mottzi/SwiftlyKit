# SwiftlyKit

Cross-compile a local Swift package into a verified Linux executable and its
runtime resources—right from your Apple silicon Mac.

SwiftlyKit handles cross-compilation with SwiftPM and Swiftly. It pairs an
official Swift toolchain with its matching Static Linux SDK. It then builds the
executable you choose and verifies that it is a statically linked ELF64 file.
SwiftlyKit also keeps the runtime resource bundles that the selected product
needs. One `async` call takes you from package to runnable output. A staged API
lets apps inspect and authorize changes, select a product, and control build,
output, and storage settings.

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

Add SwiftlyKit to your project with Swift Package Manager.

In Xcode, select **File > Add Package Dependencies** and enter:

```text
https://github.com/mottzi/SwiftlyKit.git
```

Select version `0.1.0` or later. Then add the `SwiftlyKit` library to your target.

To add SwiftlyKit in `Package.swift`, add the package and product dependencies:

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

This fast track uses these defaults:

- The package must have exactly one executable product.
- The target is x86-64 Linux.
- The build configuration is release.
- SwiftlyKit selects the toolchain automatically.
- The executable is not stripped.
- The executable and any runtime resources stay in SwiftPM scratch storage.
- The package's default traits remain enabled.

Specify a product, target, toolchain, or configuration when you need a different
result:

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

To keep the output, publish the complete runnable directory outside scratch
storage. This example resets scratch storage after publication succeeds:

```swift
let publicationDirectory = URL(filePath: "/path/to/output/MyTool")
let result = try await SwiftlyKit.build(
    packageRoot,
    product: "MyTool",
    storage: .directory(URL(filePath: "/path/to/scratch")),
    output: .publish(to: publicationDirectory, cleanup: .reset),
    strip: true
)
```

`result.executable` is `/path/to/output/MyTool/MyTool`.
`result.resourceBundles` contains any resource bundles the tool needs.

By default, SwiftlyKit does not replace the destination. Set `replacingExisting`
to atomically replace an earlier complete output directory at a stable URL:

```swift
let result = try await SwiftlyKit.build(
    packageRoot,
    output: .publish(to: publicationDirectory, replacingExisting: true)
)
```

`BuildResult` contains the executable, its required resource bundles, and their
directory. Keep the whole published directory together when you move, upload,
or deploy it.

> [!IMPORTANT]
> The fast track authorizes SwiftlyKit to install Swiftly, the selected
> toolchain, and its SDK when needed. It can also resolve dependencies and
> update `Package.resolved`. Use the staged workflow if your app must ask
> before making these changes. See [Removal plans](#removal-plans) if the
> caller must record resources for later removal.

## Staged workflow

The staged API separates read-only assessment from operations that can change
the environment or package. One `LocalBuildEnvironment` keeps later operations
tied to the assessed package, target, toolchain, SDK, environment values, and
package traits.

### 1. Assess the environment

`assess(_:for:toolchain:)` validates the host and package. It selects an exact
official Swift release and Static Linux SDK. It does not install components or
resolve package dependencies.

Assessment normally uses the current Swift.org release catalog. During an
outage, SwiftlyKit can use a cached catalog only to select a toolchain and
matching SDK that are already installed. See
[Catalog availability](#catalog-availability) for the limits of this fallback.

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

Use the properties of `EnvironmentAssessment` to show the proposed changes to
the user. The assessment reports whether Swiftly, the toolchain, and the SDK are
available.

If your app lets the user choose a toolchain, call
`compatibleEnvironments(_:for:)` instead. This method makes one read-only
discovery pass:

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
`select(_:)` applies `.automatic` or `.exact` without inspecting the package,
catalog, or installed tools again. The selected assessment passes directly to
`prepare(_:)`. The collection is empty if no official stable release is
compatible.

### 2. Prepare the environment

Pass the selected assessment to `prepare(_:)`. This call authorizes only the
components in `requiredComponents` and returns the Local build environment:

```swift
let environment = try await kit.prepare(assessment)
```

You can also bind values that every later SwiftPM operation must use:

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

You must call `prepare(_:)` even when `requiresInstallation` is `false`. The
other staged operations require the returned environment.

Preparation also captures the SwiftPM environment and package traits for the
rest of the staged workflow. See [SwiftPM configuration](#swiftpm-configuration)
for the available policies and their security limits.

If `Package.swift` or the applicable `.swift-version` file changes after
assessment, `prepare(_:)` throws `SwiftlyKitError.staleAssessment`. Run
assessment again before you continue.

#### Removal plans

Preparation can stop after SwiftlyKit starts a toolchain or SDK installation.
Supply `recordRemovalPlan` if the caller must retain an exact removal request
for those resources:

```swift
let recorder: EnvironmentRemovalPlan.Recorder = { plan in
    try await removalPlanStore.replace(with: plan)
}

let environment = try await kit.prepare(
    assessment,
    recordRemovalPlan: recorder
)
```

The fast track accepts the same recorder:

```swift
let result = try await SwiftlyKit.build(
    packageRoot,
    recordRemovalPlan: recorder
)
```

The recorder is optional. SwiftlyKit awaits it after live inspection finds a
missing toolchain or SDK and before it starts that installation command. If
both resources are missing, SwiftlyKit calls the recorder first with a
toolchain plan and then with a full environment plan. Store each call as the
latest plan. If the recorder throws, SwiftlyKit does not start that installation
command and propagates the error unchanged.

Because the recorder finishes first, the stored plan remains available if the
installation fails, is canceled, or the process stops. A plan can name a
resource that the installation command did not create. The plan is
conservative; it is not proof of ownership.

SwiftlyKit does not persist plans or remove resources automatically. Start a
fresh, non-canceled operation to remove a persisted plan:

```swift
let plan = try await removalPlanStore.load()
try await SwiftlyKit.remove(plan)
```

Removal reads live Swiftly state again. It treats an observable absent target
as success. It refuses active or default toolchains and uninspectable SDK
state. A full environment plan removes the exact SDK before its toolchain.

Plans are Codable. You can also create a plan for exact resources that were not
installed by the current operation:

```swift
let toolchainPlan = EnvironmentRemovalPlan.toolchain(
    SwiftVersion(major: 6, minor: 3, patch: 3)
)

let sdkPlan = try EnvironmentRemovalPlan.staticLinuxSDK(
    identifier: "swift-6.3.3-RELEASE_static-linux-0.1.0"
)

let environmentPlan = try EnvironmentRemovalPlan.environment(
    toolchain: SwiftVersion(major: 6, minor: 3, patch: 3),
    staticLinuxSDKIdentifier: "swift-6.3.3-RELEASE_static-linux-0.1.0"
)
```

### 3. Select an executable product

SwiftlyKit asks SwiftPM for the executable products in the prepared package:

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
    storage: .directory(URL(filePath: "/path/to/scratch")),
    output: .publish(to: publicationDirectory, cleanup: .reset),
    strip: true
)

let result: BuildResult

do {
    result = try await kit.build(request, using: environment)
} catch SwiftlyKitError.dependencyResolutionRequired {
    try await kit.resolveDependencies(using: environment)
    result = try await kit.build(request, using: environment)
}
```

A staged build never resolves dependencies automatically.
`resolveDependencies(using:)` can access the network and update
`Package.resolved`.

SwiftlyKit monitors the root package and its resolved dependencies during
compilation. If relevant source or dependency state changes, it withholds the
result and throws `SwiftlyKitError.packageChangedDuringBuild`. See
[Source stability](#source-stability) for the exact scope and limits.

### Build request options

| Option | Default | Behavior |
| --- | --- | --- |
| `configuration` | `.release` | Selects the SwiftPM debug or release configuration. |
| `jobs` | `nil` | Limits concurrent SwiftPM build jobs. `nil` uses the SwiftPM default. |
| `storage` | `.packageDefault` | Uses the package `.build` directory. `.directory(URL)` selects an explicit SwiftPM scratch directory. |
| `output` | `.buildStorage` | Returns a `BuildResult` in SwiftPM build storage. `.publish(to:replacingExisting:cleanup:)` copies the runnable files to your directory, runs the requested cleanup, and returns the result. |
| `strip` | `false` | Strips a SwiftlyKit-owned executable with the selected toolchain, then verifies it again. |

An explicit `jobs` value must be positive. SwiftlyKit rejects zero and negative
values with `SwiftlyKitError.invalidBuildJobCount` before it runs a subprocess.

Stripping never changes the executable that SwiftPM produces or any resource
bundle. With `.buildStorage`, SwiftlyKit returns a deterministic stripped
executable beside the required resources in the binary directory. With
`.publish`, SwiftlyKit strips and verifies only the staged executable. It then
publishes the complete directory atomically. A strip failure publishes nothing.

The parent of a publication directory must exist. By default, SwiftlyKit
throws `SwiftlyKitError.outputAlreadyExists` if the destination exists. Set
`replacingExisting` to replace the complete existing directory atomically.
SwiftlyKit publishes only after stripping and verification succeed. It starts
cleanup only after publication succeeds.

`BuildCleanup.retain` keeps all scratch storage and is the default.
`BuildCleanup.clean` delegates to `swift package clean`. It removes compiled
products and intermediates but keeps SwiftPM repository clones, dependency
checkouts, downloaded artifacts, and workspace state.
`BuildCleanup.reset` delegates to `swift package reset` and removes the entire
effective scratch directory, including those retained dependencies. Both modes
work with `.packageDefault` and `.directory(URL)` storage.

Automatic `.clean` or `.reset` requires the publication directory outside the
effective scratch directory. SwiftlyKit completes atomic publication before
cleanup. If publication succeeds but cleanup fails, it throws
`SwiftlyKitError.postBuildCleanupFailed`. The error's output URL identifies the
published directory, which remains available.

To clean or reset storage separately from a build, use the staged cleanup
operations:

```swift
try await kit.cleanBuildArtifacts(
    in: request.storage,
    using: environment
)

try await kit.resetBuildStorage(
    in: request.storage,
    using: environment
)
```

Standalone cleanup uses the same effective storage as a build. Cleaning keeps
reusable dependency state. Resetting deletes the complete selected directory;
do not select a directory containing files unrelated to SwiftPM build storage.
SwiftlyKit rejects build storage equal to or above the package root. Both
operations leave package sources and `Package.resolved` untouched.

## Toolchain selection

The default `.automatic` policy selects a toolchain in this order:

1. The compatible official stable version in the nearest `.swift-version` file.
2. The newest compatible installed toolchain and matching SDK.
3. The newest compatible official stable toolchain and matching SDK.

The selected version must support the package's `swift-tools-version` and the
requested architecture.

Use `.exact` when your app must select one official stable release. The fast
track accepts the selection directly:

```swift
let result = try await SwiftlyKit.build(
    packageRoot,
    toolchain: .exact(
        SwiftVersion(major: 6, minor: 2, patch: 1)
    )
)
```

Pass the same selection during assessment in the staged workflow:

```swift
let assessment = try await kit.assess(
    packageRoot,
    for: .linux(.x86_64),
    toolchain: .exact(
        SwiftVersion(major: 6, minor: 2, patch: 1)
    )
)
```

Use the lossless text initializer for a command-line argument, text field, or
stored preference:

```swift
let versionText = "6.2.1"

if let version = SwiftVersion(versionText) {
    let assessment = try choices.select(.exact(version))
    print("Selected Swift \(assessment.swiftVersion).")
}
```

The initializer accepts two or three ASCII decimal components. It normalizes
`"6.2"` to `"6.2.0"` and rejects snapshots, labels, and arbitrary Swiftly
selectors.

Use `compatibleEnvironments(_:for:)` if the caller does not know the exact
version in advance. The method returns the available exact assessments. Store
the user's choice as a `ToolchainSelection`, then call `select(_:)` before
preparation.

SwiftlyKit does not use snapshot toolchains, development branches, custom SDKs,
or arbitrary Swiftly selectors.

## SwiftPM configuration

`SwiftPMTraits.packageDefaults` is the default and keeps the package's declared
default traits. Use `.none` to disable all traits, `.all` to enable every trait,
or `SwiftPMTraits(_:includingDefaults:)` to select named traits. SwiftlyKit
validates names, removes duplicates, and orders them consistently. SwiftPM
reports whether the package declares each valid name.

For environment values, `.plain` adds or replaces a nonsecret value,
`.sensitive` adds or replaces a value that SwiftlyKit redacts from its output,
and `.unset` removes an inherited value. SwiftlyKit automatically treats known
SwiftPM credential variables as sensitive. SwiftlyKit rejects invalid values.
It also rejects variables that could replace the prepared toolchain, SDK,
Swiftly storage, or protected host state. SwiftlyKit removes inherited compiler
and SDK overrides.

The captured environment and traits apply to package inspection, dependency
resolution, builds, and cleanup. They do not apply to Swiftly preparation,
downloads, stripping, publication, or executable verification. Changes to the
host environment or input values after preparation do not alter the captured
configuration.

> [!WARNING]
> SwiftlyKit redacts these values only in output that it returns or streams. A
> trusted manifest, plugin, SwiftPM cache, or external tool can still read or
> store supplied values. Use a credential store for long-lived secrets.

## Progress and command output

Pass one event handler to a mutating operation. SwiftlyKit awaits each handler
call. This provides backpressure. SwiftlyKit does not keep an event log.

```swift
let onEvent: SwiftlyKitEvent.Handler = { event in
    switch event {
    case .progress(let progress):
        print(progress.detail)

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

The handler can receive:

- `SwiftlyKitEvent.progress` for preparation, dependency resolution, build,
  environment removal, strip, publication, and cleanup activities.
- `SwiftlyKitEvent.output` for standard output and standard error chunks from
  delegated commands.

SwiftlyKit reports activity text. It does not report a percentage when the
underlying tool cannot supply a trustworthy value.

## Supported output

SwiftlyKit builds one executable product for one of these targets:

- ARM64 Linux Musl: `.linux(.arm64)`
- x86-64 Linux Musl: `.linux(.x86_64)`

Before returning a `BuildResult`, SwiftlyKit checks that the executable:

- is a regular file with executable permissions;
- is a little-endian ELF64 executable for the requested architecture;
- has a loadable segment;
- has no dynamic interpreter; and
- declares no required dynamic libraries.

SwiftlyKit keeps only the SwiftPM `.resources` directories linked to the selected
product. It identifies these directories from the final link output and the
generated resource accessors. SwiftlyKit rejects missing or ambiguous metadata
and unsafe resource trees with `runtimeResourceVerificationFailed`. Resource
trees can contain regular files and directories. SwiftlyKit rejects symbolic
links, hard links, sockets, devices, FIFOs, and other special entries.

`.buildStorage` returns the executable and the resource bundles it needs in
SwiftPM's build directory. That directory may contain files from other builds.
Use `result.resourceBundles` instead of looking for bundles in the directory.

`.publish` copies the executable and its resource bundles to your directory.
Keep that directory together when you move or deploy it.

SwiftPM does not provide a stable interface for listing a product's runtime
resources. When the binary directory contains a `.resources` candidate,
SwiftlyKit checks SwiftPM's current link and accessor files. It fails closed if
it cannot verify which resources belong to the selected product. If the binary
directory has no `.resources` directories, SwiftlyKit treats the product as
resource-free and does not inspect those private files. See
[Architecture](Documentation/Architecture.md) for the implementation details.

The package and all its dependencies must support the selected Linux Musl
target.

## Operational behavior

### Host readiness

Interactive apps can inspect the host before asking for a package or starting a
build:

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

This check is optional. SwiftlyKit also performs it during assessment and
building. `requestCommandLineToolsInstallation()` requests
[Apple's interactive Command Line Tools installer](https://developer.apple.com/documentation/xcode/installing-the-command-line-tools)
and returns before installation finishes. The method does not install Xcode or
change the active developer directory. If developer tools are installed but not
active, select them outside SwiftlyKit.

### Catalog availability

SwiftlyKit reuses a validated Swift.org catalog in memory for one hour. It also
keeps one disposable snapshot in the current user's cache directory. If
Swift.org is unavailable, SwiftlyKit can use this snapshot only when Swiftly
reports the selected toolchain and matching SDK as fully installed. The snapshot
never authorizes installation or makes an unrecognized toolchain official.
Missing, invalid, or unsuitable cache data produces the normal `networkFailure`
result.

Only a network failure while loading the live catalog triggers the fallback.
Cancellation or an invalid live catalog does not.

`compatibleEnvironments(_:for:)` does not use this persistent fallback because
a cached snapshot cannot represent the complete current catalog. Updating the
cache does not change the package or installed environment. The snapshot
contains only public Swift.org metadata.

### Source stability

During compilation, SwiftlyKit observes the root package and all packages in the
resolved dependency graph. It checks paths, contents, executable permissions,
safe symbolic-link destinations, `Package.swift`, and `Package.resolved`. It
also detects a relevant change that is reverted before the build finishes.

SwiftlyKit excludes top-level `.build`, `.git`, and `.swiftpm` directories and
the selected scratch directory. Across all observed roots, the observation can
include at most 200,000 files and symbolic links and 8 GiB of regular-file
contents. If SwiftlyKit cannot establish or repeat the observation, it throws
`packageSourceStabilityUnavailable` before it returns an executable.

This check detects changes during compilation. It does not build from an
immutable source copy or create durable build provenance. SwiftlyKit stops
observing sources after it discovers and verifies the executable and runtime
resources. Stripping, publication, and cleanup start later.

### Environment boundaries

SwiftlyKit uses official tools in the current user's standard Swiftly and SwiftPM
locations. It does not create a private tool installation.

SwiftlyKit does not:

- modify a shell profile;
- change the default Swift toolchain;
- run `swiftly use`;
- update or replace an existing Swiftly installation;
- remove Swiftly. Exact toolchain or SDK removal is available only when the
  consumer explicitly requests environment removal;
- remove build scratch storage unless the consumer requests `.reset` or calls
  `resetBuildStorage(in:using:)`;
- install Xcode or select Apple developer tools;
- request the Command Line Tools installer unless the consumer explicitly calls
  `requestCommandLineToolsInstallation()`;
- run package tests;
- sign, archive, deploy, or run the Linux executable; or
- keep build history, logs, or artifacts.

SwiftlyKit is not a package sandbox. Supply only a package that you trust.
SwiftPM evaluates `Package.swift` and can run package plugins with the current
user's permissions.

## Concurrency, cancellation, and errors

All long operations are `async throws` functions. Across cooperating SwiftlyKit
processes for one macOS user, only one preparation, removal, dependency
resolution, build, or cleanup operation runs at a time. A waiting operation
responds to task cancellation. The fast track blocks other mutations for its
complete workflow.
The staged API blocks other mutations for one mutating call at a time.

Assessment and product discovery remain concurrent and read-only. Because their
view of installed state can become outdated, preparation checks the required
state again before making changes.

Do not start or await another mutating SwiftlyKit operation from an event
handler or removal-plan recorder. SwiftlyKit rejects the operation with
`mutationCoordinationFailed`. Direct
`swift` and `swiftly` commands, filesystem changes, and other tools do not
participate in SwiftlyKit's coordination. Do not use them to modify the same
installation, package, build storage, SDK, or output while SwiftlyKit is working.

If a process ends abruptly, a tool it launched may survive. Stop that process or
wait for it to finish before retrying.

Cancel the calling task to cancel the complete subprocess group. SwiftlyKit
removes transient publication staging directories and throws Swift's standard
`CancellationError`. It does not start unrequested cleanup.

SwiftlyKit reports operational failures as `SwiftlyKitError`. This type conforms
to `LocalizedError` and provides a user-facing description. Common control-flow
errors include:

- `mutationCoordinationFailed`
- `networkFailure`
- `dependencyResolutionRequired`
- `unsupportedHost`
- `developerToolsUnavailable`
- `commandLineToolsInstallationRequestFailed`
- `invalidSwiftPMEnvironmentVariable`
- `invalidSwiftPMTrait`
- `invalidBuildJobCount`
- `executableProductSelectionRequired`
- `staleAssessment`
- `packageChangedDuringBuild`
- `packageSourceStabilityUnavailable`
- `runtimeResourceVerificationFailed`
- `outputAlreadyExists`
- `outputPublicationFailed`
- `unsafeBuildStorage`
- `outputInsideBuildStorage`
- `unsafeEnvironmentRemoval`
- `environmentRemovalFailed`
- `postBuildCleanupFailed`
- `buildArtifactCleanupFailed`
- `buildStorageResetFailed`

Handle cancellation separately when your app must show different status:

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

## Interface overview

| Type | Purpose |
| --- | --- |
| `SwiftlyKit` | Provides host inspection, explicit recovery, the fast track, and staged operations. |
| `HostReadiness` | Reports whether the host is supported and developer tools are active, without inspecting a package. |
| `EnvironmentChoices` | Lists exact compatible assessments and applies automatic or exact selection without another system inspection. |
| `EnvironmentAssessment` | Describes the selected environment and required installations. |
| `EnvironmentRemovalPlan` | Describes exact caller-requested toolchain/SDK removal; Codable and persistable. |
| `SwiftPMEnvironment` | Adds, redacts, or removes values for one complete SwiftPM workflow. |
| `SwiftPMTraits` | Selects package defaults, no traits, all traits, or a validated explicit set. |
| `LocalBuildEnvironment` | Binds later operations to one prepared package, target, toolchain, SDK, and SwiftPM configuration. |
| `ExecutableProducts` | Lists discovered products and selects a named or sole executable. |
| `BuildRequest` | Selects one product and its build options. |
| `BuildResult` | Contains the executable, its required resource bundles, and their directory. |
| `BuildStorage` | Selects package-default or explicit SwiftPM scratch storage. |
| `BuildOutput`, `BuildCleanup` | Control output publication and later cleanup of build storage. |
| `BuildTarget`, `LinuxArchitecture` | Select the Linux architecture. |
| `BuildConfiguration` | Selects a debug or release build. |
| `ToolchainSelection`, `SwiftVersion` | Select a release and convert exact versions to or from text. |
| `ExecutableProduct` | Identifies an executable product reported by SwiftPM. |
| `SwiftlyKitEvent`, `SwiftlyKitEvent.Handler` | Report progress and delegated command output. |
| `SwiftlyKitError` | Reports typed operational failures. |

## Development

Run the test suite from the repository root:

```sh
swift test
```

To run the real-system cross-compilation acceptance test on a prepared host, use:

```sh
SWIFTLYKIT_RUN_ACCEPTANCE=1 swift test --filter CrossCompilationAcceptanceTests
```

The test uses a fixture with resources in a local dependency. It never authorizes
installation. The test requires compatible Swiftly, Swift 6.3.3, and its
matching Static Linux SDK. These components must already be installed. The test
builds and verifies both supported architectures. It also verifies the published
runnable directory for each architecture in temporary storage. The test confirms
that a second identical build in managed build storage performs no compilation
or linking.

For the internal design, see [Architecture](Documentation/Architecture.md).

## License

SwiftlyKit is available under the MIT License. See [LICENSE](LICENSE).

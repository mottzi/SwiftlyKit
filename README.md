# SwiftlyKit

Cross-compile a local Swift package into a self-contained Linux executable—right
from your Apple silicon Mac.

SwiftlyKit handles the cross-compilation pipeline with SwiftPM and Swiftly. It
pairs an official Swift toolchain with its matching Static Linux SDK, builds the
executable you choose, and verifies the result is a statically linked ELF64 file.
One `async` call takes you from package to binary; the staged API gives your app
the control to inspect and authorize installations, select a product, and shape
the build, output copy, and scratch-storage lifecycle.

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

### Requirements

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

### Inspect host readiness

An interactive consumer can inspect host readiness before it asks for a package
or starts a build. This read-only operation does not load the Swift.org catalog
or inspect installed Swiftly state:

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

Assessment and building still perform the same readiness check and throw
`SwiftlyKitError.developerToolsUnavailable` or `SwiftlyKitError.unsupportedHost`
if the caller does not inspect first. The inspection is optional.

The explicit recovery operation requests
[Apple's system installer](https://developer.apple.com/documentation/xcode/installing-the-command-line-tools).
It returns when macOS accepts the request, not when installation finishes. The
user must click Install, accept Apple's license, and then retry inspection,
assessment, or building. The operation is a no-op when an active Xcode or
Command Line Tools SDK is already usable. It never installs Xcode or changes the
active developer directory; if developer tools are installed but not selected,
the consumer must select them outside SwiftlyKit.

## Quick start

Import SwiftlyKit and pass the root of a local Swift package to `build(_:)`:

```swift
import Foundation
import SwiftlyKit

let packageRoot = URL(filePath: "/path/to/package")
let executable = try await SwiftlyKit.build(packageRoot)

print(executable.path)
```

This fast track uses these defaults:

- The package must have exactly one executable product.
- The target is x86-64 Linux.
- The build configuration is release.
- SwiftlyKit selects the toolchain automatically.
- The executable is not stripped.
- The executable stays in SwiftPM scratch storage.

Specify a product, target, toolchain, or configuration when you need a different
result:

```swift
let executable = try await SwiftlyKit.build(
    packageRoot,
    product: "MyTool",
    for: .linux(.arm64),
    toolchain: .exact(SwiftVersion(major: 6, minor: 2, patch: 1)),
    configuration: .debug
)
```

Copy the executable out of scratch storage and remove all build storage after a
successful copy when you need a disposable one-shot build:

```swift
let destination = URL(filePath: "/path/to/output/MyTool")
let executable = try await SwiftlyKit.build(
    packageRoot,
    product: "MyTool",
    storage: .directory(URL(filePath: "/path/to/scratch")),
    output: .copy(to: destination, cleanup: .reset),
    strip: true
)
```

Set `replacingExisting` only if the build must atomically publish to a stable
output URL that can already contain an earlier executable:

```swift
let executable = try await SwiftlyKit.build(
    packageRoot,
    output: .copy(to: destination, replacingExisting: true)
)
```

> [!IMPORTANT]
> The fast track authorizes SwiftlyKit to install required environment
> components. It also authorizes dependency resolution when SwiftPM requires it.
> Use the staged API when your app must request authorization before these
> changes.

## Staged workflow

The staged API separates read-only assessment from operations that can change
the environment or package. One `LocalBuildEnvironment` binds all later
operations to the assessed package, target, toolchain, SDK, and SwiftPM process
environment snapshot.

### 1. Assess the environment

`assess(_:for:toolchain:)` validates the host and package. It selects an exact
official Swift release and Static Linux SDK. It does not install components or
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

Use the properties of `EnvironmentAssessment` to show the proposed changes to
the user. The assessment reports whether Swiftly, the toolchain, and the SDK are
available.

If your app lets the user choose a toolchain, replace the direct assessment with
one read-only discovery pass:

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

`EnvironmentChoices` contains exact compatible assessments once each in
newest-first order. `select(_:)` applies either `.automatic` or `.exact` to the
same captured package, catalog, and installed state without more I/O. Each
selected assessment passes directly to `prepare(_:)`. An automatic selection
failure does not hide compatible exact choices. The collection is empty if no
official stable release is compatible.

### 2. Prepare the environment

Pass the accepted assessment to `prepare(_:)`. This call authorizes only the
components in `requiredComponents`. You can also bind values that every later
SwiftPM operation must observe:

```swift
let values = try SwiftPMEnvironment([
    "PACKAGE_FLAVOR": .plain("production"),
    "PKG_CONFIG_PATH": .plain("/opt/linux/lib/pkgconfig"),
    "SWIFTPM_REGISTRY_TOKEN": .sensitive(token),
    "UNWANTED_PARENT_VALUE": .unset
])

let environment = try await kit.prepare(
    assessment,
    swiftPMEnvironment: values
)
```

You must call `prepare(_:)` even when `requiresInstallation` is `false`. The
returned environment is the capability that the other staged operations need.
SwiftlyKit captures the host environment during this call. Later changes to the
host environment or the input dictionary do not change the prepared snapshot.

`.plain` adds or replaces a nonsecret value, `.sensitive` adds or replaces a
value that SwiftlyKit redacts from its output, and `.unset` removes an inherited
value. SwiftlyKit automatically treats its supported SwiftPM credential
variables as sensitive. It rejects invalid names, NUL values, and values that
can replace the selected toolchain, SDK, Swiftly storage, or protected host
state. Inherited compiler and SDK overrides are removed.

The automatically sensitive names are `SWIFTPM_REGISTRY_TOKEN`,
`SWIFTPM_REGISTRY_LOGIN`, `SWIFTPM_REGISTRY_PASSWORD`,
`SWIFTPM_SOURCE_CONTROL_TOKEN`, and `SWIFTPM_NETRC_DATA`. Protected names are
`CFFIXED_USER_HOME`, `HOME`, `PATH`, `DEVELOPER_DIR`, Swiftly home, bin, and
toolchain-directory names, compiler and linker selectors such as `SWIFT_EXEC`,
`CC`, `AR`, and `LIBTOOL`, SDK and toolchain selectors, and SwiftPM custom tool
directories.

The snapshot applies to package inspection, graph discovery, dependency
resolution, build, bin-path lookup, clean, and reset. Caller changes do not
reach Swiftly preparation, downloads, stripping, copying, or verification.

> [!WARNING]
> Redaction protects output returned or streamed by SwiftlyKit. A trusted
> manifest, plugin, SwiftPM cache, or external tool can still consume or persist
> supplied values. SwiftlyKit keeps no credential profile and does not replace a
> credential store.

If `Package.swift` or the applicable `.swift-version` file changes after
assessment, preparation throws `SwiftlyKitError.staleAssessment`. Run assessment
again before you continue.

### 3. Select an executable product

SwiftlyKit asks SwiftPM for the executable products in the prepared package:

```swift
let products = try await kit.executableProducts(using: environment)
let product = try products.select("MyTool")
```

Product discovery does not resolve package dependencies. The returned
`ExecutableProducts` value remains iterable and indexable. Call `select()`
without a name if the package must contain exactly one executable product.

### 4. Build the product

Create a `BuildRequest` and use the prepared environment:

```swift
let output = URL(filePath: "/path/to/output/MyTool")
let request = BuildRequest(
    product,
    configuration: .release,
    storage: .directory(URL(filePath: "/path/to/scratch")),
    output: .copy(to: output, cleanup: .reset),
    strip: true
)

let executable: URL

do {
    executable = try await kit.build(request, using: environment)
} catch SwiftlyKitError.dependencyResolutionRequired {
    try await kit.resolveDependencies(using: environment)
    executable = try await kit.build(request, using: environment)
}
```

A staged build never resolves dependencies automatically. The separate
`resolveDependencies(using:)` call can access the network and can update
`Package.resolved`.

Every build establishes source stability before compilation. SwiftlyKit observes
the root package and every package in SwiftPM's resolved dependency graph. It
compares deterministic snapshots before and after compilation and also records
recursive filesystem events, including a change that is reverted before the
build finishes. A relevant change withholds the result and throws
`SwiftlyKitError.packageChangedDuringBuild`. If SwiftlyKit cannot establish or
recapture the evidence, it fails closed with
`SwiftlyKitError.packageSourceStabilityUnavailable`.

The observation includes file paths, contents, executable permissions, safe
symbolic-link destinations, `Package.swift`, and `Package.resolved`. It excludes
each package root's top-level `.build`, `.git`, and `.swiftpm` directories and
the selected scratch directory. Resolved dependency roots inside scratch remain
included. Observation ends after compilation and executable verification;
optional stripping, copying, and cleanup do not read package source.
One observation accepts at most 200,000 regular files and symbolic links and
8 GiB of regular-file contents across all source roots. Larger graphs fail with
`packageSourceStabilityUnavailable` before compilation.

This guarantee detects source changes during a build. It does not build from an
immutable source copy, retain a source fingerprint, or create durable provenance
for the returned executable.

### Build request options

| Option | Default | Behavior |
| --- | --- | --- |
| `configuration` | `.debug` | Selects the SwiftPM debug or release configuration. |
| `storage` | `.packageDefault` | Uses the package `.build` directory. `.directory(URL)` selects an explicit SwiftPM scratch directory. |
| `output` | `.buildStorage` | Returns the executable in scratch storage. `.copy(to:replacingExisting:cleanup:)` atomically publishes it and then performs the requested cleanup. |
| `strip` | `false` | Uses the selected toolchain to strip an output copy, and then verifies it again. |

Stripping never changes SwiftPM's produced executable. With `.buildStorage`,
SwiftlyKit returns a deterministic stripped copy inside build storage. With
`.copy`, SwiftlyKit strips and verifies a temporary sibling before it atomically
publishes the requested output. A strip failure publishes nothing.

The parent directory of a copied output must exist. By default, SwiftlyKit
throws `SwiftlyKitError.outputAlreadyExists` if the destination exists. Set
`replacingExisting` to replace that exact item atomically. SwiftlyKit publishes
only after stripping and verification succeed, and performs cleanup only after
publication succeeds.

`BuildCleanup.retain` keeps all scratch storage and is the default.
`BuildCleanup.clean` delegates to `swift package clean`: it removes compiled
products and intermediates while retaining SwiftPM repository clones,
dependency checkouts, downloaded artifacts, and workspace state.
`BuildCleanup.reset` delegates to `swift package reset` and removes the entire
effective scratch directory, including those retained dependencies. Both modes
work with `.packageDefault` and `.directory(URL)` storage.

Automatic `.clean` or `.reset` requires copied output outside the effective
scratch directory. SwiftlyKit completes the atomic copy before cleanup. If the
copy succeeds but cleanup fails, it throws
`SwiftlyKitError.postBuildCleanupFailed`; the associated output URL identifies
the successfully copied executable that remains available.

Use the staged cleanup operations when cleanup does not belong to the build
call:

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

The retained SDK selection is a small hidden directory of symlinks beneath
`.swiftlykit/sdk-selections` in scratch storage. Its stable path lets SwiftPM
reuse compiled and linked outputs across identical builds while exposing only
the exact prepared SDK. Cleaning or resetting build storage removes this
metadata; the next build recreates it.

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
let executable = try await SwiftlyKit.build(
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
version in advance. Iterate over the returned exact assessments, keep the user
choice as a `ToolchainSelection`, and call `select(_:)` before preparation.

SwiftlyKit does not use snapshot toolchains, development branches, custom SDKs,
or arbitrary Swiftly selectors.

## Progress and command output

Pass one event handler to a mutating operation. SwiftlyKit awaits the handler, so
the handler provides backpressure. SwiftlyKit does not keep an event log.

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
  strip, copy, and cleanup activities.
- `SwiftlyKitEvent.output` for standard output and standard error chunks from
  delegated commands.

SwiftlyKit reports activity text. It does not report a percentage when the
underlying tool cannot supply a trustworthy value.

## Supported output

SwiftlyKit 0.1.0 builds one executable product for one of these targets:

- ARM64 Linux Musl: `.linux(.arm64)`
- x86-64 Linux Musl: `.linux(.x86_64)`

Before SwiftlyKit returns a URL, it verifies that the result:

- is a regular file with executable permissions;
- is a little-endian ELF64 executable for the requested architecture;
- has a loadable segment;
- has no dynamic interpreter; and
- declares no required dynamic libraries.

SwiftlyKit rejects an executable product that needs a SwiftPM runtime resource
bundle. Resources embedded in code and Apple privacy metadata do not require a
runtime bundle and are supported. The package and all its dependencies must
support the selected Linux Musl target.

## Environment behavior

SwiftlyKit uses official tools in the current user's normal Swiftly and SwiftPM
locations. It does not create a private tool installation.

SwiftlyKit does not:

- modify a shell profile;
- change the default Swift toolchain;
- run `swiftly use`;
- update or replace an existing Swiftly installation;
- remove Swiftly, a toolchain, or an SDK;
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

All long operations use Swift concurrency and are `async throws` functions. For
one macOS user, SwiftlyKit consumers that use coordination protocol v1 admit at
most one mutating public operation at a time. The coordinated operations are
preparation, dependency resolution, builds, and cleanup. A waiting operation
observes task cancellation. The static fast track holds one lease for its
complete workflow. Each staged mutation holds one lease for that public call,
so another consumer can run between staged calls.

Read-only assessment and product discovery do not acquire the mutation lease.
They can run concurrently with preparation and can observe installed state that
changes before the caller uses it. Preparation reinspects required state and
rejects changed package selection inputs. These observations are not
transactional snapshots of the user environment.

SwiftlyKit uses a persistent advisory lock file in the current user's Application
Support directory. The kernel releases ownership if a process terminates; the
file can remain and must not be deleted as stale state. SwiftlyKit restricts the
file to the current user each time it opens it. Child tools do not inherit the
descriptor. This intentionally serializes even disjoint SwiftlyKit mutations to
protect shared Swiftly, toolchain, and SDK state. Direct and task-context-
inheriting reentrant mutations fail with `mutationCoordinationFailed`. An event
handler must not await another mutating SwiftlyKit operation, including through
`Task.detached`, because detached work does not inherit reentrancy context.

`requestCommandLineToolsInstallation()` does not acquire the mutation lease. It
requests machine-level system interaction and returns before installation
finishes. Concurrent consumers can issue duplicate requests.

The lock coordinates SwiftlyKit consumers only. A direct `swift` or `swiftly`
command and direct filesystem mutation do not acquire it. Tool-owned locks cover
only part of the workflow and do not protect SwiftlyKit's parent-side inspection,
optional stripping, atomic publication, or requested cleanup. Do not run those
external mutations against the same user installation, package, build storage,
SDK, or output while SwiftlyKit is working.

The mutation lease does not freeze package sources. Builds separately monitor
and compare the complete resolved package graph during compilation. A detected
source or dependency-state mutation withholds the result. Source observation
does not coordinate the editor or process that made the change, and it does not
protect unrelated direct mutations of build storage, SDK state, or output paths.

If a SwiftlyKit process terminates abruptly, an already launched tool can survive
after the kernel releases the lease. Stop that orphan or wait for it before a
retry. SwiftlyKit cannot coordinate or detect arbitrary unmodified external
processes.

Cancel the calling task to cancel the complete subprocess group. SwiftlyKit
removes transient atomic-copy files and throws Swift's standard
`CancellationError`. It does not start unrequested cleanup.

Operational failures use `SwiftlyKitError`. It conforms to `LocalizedError` and
provides a user-facing description. Common control-flow errors include:

- `mutationCoordinationFailed`
- `dependencyResolutionRequired`
- `developerToolsUnavailable`
- `commandLineToolsInstallationRequestFailed`
- `invalidSwiftPMEnvironmentVariable`
- `executableProductSelectionRequired`
- `staleAssessment`
- `packageChangedDuringBuild`
- `packageSourceStabilityUnavailable`
- `outputAlreadyExists`
- `unsafeBuildStorage`
- `outputInsideBuildStorage`
- `postBuildCleanupFailed`
- `buildArtifactCleanupFailed`
- `buildStorageResetFailed`

Handle cancellation separately when your app must show different status:

```swift
do {
    let executable = try await SwiftlyKit.build(packageRoot)
    print(executable.path)
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
| `HostReadiness` | Reports host support and active developer tools readiness without a package. |
| `EnvironmentChoices` | Lists exact compatible assessments and applies automatic or exact selection without more I/O. |
| `EnvironmentAssessment` | Describes the selected environment and required installations. |
| `SwiftPMEnvironment` | Adds, redacts, or removes values for one complete SwiftPM workflow. |
| `LocalBuildEnvironment` | Binds later operations to one prepared package, target, toolchain, SDK, and process snapshot. |
| `ExecutableProducts` | Lists discovered products and selects a named or sole executable. |
| `BuildRequest` | Selects one product and its build options. |
| `BuildStorage` | Selects package-default or explicit SwiftPM scratch storage. |
| `BuildOutput`, `BuildCleanup` | Select executable copying and retained, cleaned, or reset build storage. |
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

Run the real-system cross-compilation acceptance test explicitly on a prepared
host. It uses SwiftlyKit's dependency-free fixture package and never authorizes installation:

```sh
SWIFTLYKIT_RUN_ACCEPTANCE=1 swift test --filter CrossCompilationAcceptanceTests
```

The acceptance tests require compatible Swiftly, Swift 6.3.3, and its matching
Static Linux SDK to already be installed. They build and verify both supported
architectures in temporary scratch storage and prove that a second identical
build performs no compilation or linking.

For the internal design, see [Architecture](Documentation/Architecture.md). For
the complete 0.1.0 release boundary, see [MVP 0.1.0](Documentation/MVP-0.1.0.md).

## License

SwiftlyKit is available under the MIT License. See [LICENSE](LICENSE).

# SwiftlyKit

Cross-compile a local Swift package into a self-contained Linux executable—right
from your Apple silicon Mac.

SwiftlyKit handles the cross-compilation pipeline with SwiftPM and Swiftly. It
pairs an official Swift toolchain with its matching Static Linux SDK, builds the
executable you choose, and verifies the result is a statically linked ELF64 file.
One `async` call takes you from package to binary; the staged API gives your app
the control to inspect and authorize installations, select a product, and shape
the build.

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

### Request missing Command Line Tools

Assessment and building throw `SwiftlyKitError.developerToolsUnavailable` when
no usable macOS SDK is active. An unsandboxed consumer can respond by requesting
[Apple's system installer](https://developer.apple.com/documentation/xcode/installing-the-command-line-tools):

```swift
do {
    let executable = try await SwiftlyKit.build(packageRoot)
    print(executable.path)
} catch SwiftlyKitError.developerToolsUnavailable {
    try await SwiftlyKit.requestCommandLineToolsInstallation()
    print("Finish the installation in the macOS dialog, then try again.")
}
```

The request returns when macOS accepts it, not when installation finishes. The
user must click Install, accept Apple's license, and then retry assessment or
building. The operation is a no-op when an active Xcode or Command Line Tools
SDK is already usable. It never installs Xcode or changes the active developer
directory; if developer tools are installed but not selected, the consumer must
select them outside SwiftlyKit.

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
- The executable stays in SwiftPM scratch storage.

Specify a product, target, or configuration when you need a different result:

```swift
let executable = try await SwiftlyKit.build(
    packageRoot,
    product: "MyTool",
    for: .linux(.arm64),
    configuration: .debug
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
operations to the assessed package, target, toolchain, and SDK.

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

### 2. Prepare the environment

Pass the accepted assessment to `prepare(_:)`. This call authorizes only the
components in `requiredComponents`.

```swift
let environment = try await kit.prepare(assessment)
```

You must call `prepare(_:)` even when `requiresInstallation` is `false`. The
returned environment is the capability that the other staged operations need.

If `Package.swift` or the applicable `.swift-version` file changes after
assessment, preparation throws `SwiftlyKitError.staleAssessment`. Run assessment
again before you continue.

### 3. Select an executable product

SwiftlyKit asks SwiftPM for the executable products in the prepared package:

```swift
let products = try await kit.executableProducts(using: environment)

guard let product = products.first(where: { $0.name == "MyTool" }) else {
    throw SwiftlyKitError.executableProductNotFound("MyTool")
}
```

Product discovery does not resolve package dependencies.

### 4. Build the product

Create a `BuildRequest` and use the prepared environment:

```swift
let output = URL(filePath: "/path/to/output/MyTool")
let request = BuildRequest(
    product,
    configuration: .release,
    output: output,
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

### Build request options

| Option | Default | Behavior |
| --- | --- | --- |
| `configuration` | `.debug` | Selects the SwiftPM debug or release configuration. |
| `scratchDirectory` | `nil` | Uses the package `.build` directory. SwiftlyKit retains exact-SDK selection metadata inside the effective scratch directory and does not remove it. |
| `output` | `nil` | Returns the executable in scratch storage. A supplied destination receives an atomic copy. |
| `strip` | `false` | Uses the selected toolchain to strip the executable, and then verifies it again. |
| `environment` | `[:]` | Adds or replaces values for build, bin-path, and strip subprocesses. SwiftlyKit keeps values that protect the prepared toolchain and SDK. |

The parent directory of `output` must exist. SwiftlyKit never replaces an
existing item at the output URL. It throws `SwiftlyKitError.outputAlreadyExists`
if the destination exists.

The retained SDK selection is a small hidden directory of symlinks beneath
`.swiftlykit/sdk-selections` in scratch storage. Its stable path lets SwiftPM
reuse compiled and linked outputs across identical builds while exposing only
the exact prepared SDK. Removing scratch storage removes this metadata too.

## Toolchain selection

The default `.automatic` policy selects a toolchain in this order:

1. The compatible official stable version in the nearest `.swift-version` file.
2. The newest compatible installed toolchain and matching SDK.
3. The newest compatible official stable toolchain and matching SDK.

The selected version must support the package's `swift-tools-version` and the
requested architecture.

Use `.exact` when your app must select one official stable release:

```swift
let assessment = try await kit.assess(
    packageRoot,
    for: .linux(.x86_64),
    toolchain: .exact(
        SwiftVersion(major: 6, minor: 2, patch: 1)
    )
)
```

SwiftlyKit does not use snapshot toolchains, development branches, custom SDKs,
or arbitrary Swiftly selectors.

## Progress and command output

Pass one event handler to a mutating operation. SwiftlyKit awaits the handler, so
the handler provides backpressure. SwiftlyKit does not keep an event log.

```swift
let onEvent: EventHandler = { event in
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
  strip, and publication activities.
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
- remove Swiftly, a toolchain, an SDK, or build scratch storage;
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

All long operations use Swift concurrency and are `async throws` functions. One
`SwiftlyKit` value serializes preparation, dependency resolution, and builds.
Read-only assessment and product discovery can run concurrently.

Cancel the calling task to cancel the complete subprocess group. SwiftlyKit
retains SwiftPM scratch state, including exact-SDK selection metadata, removes
transient staging files outside scratch, and throws Swift's standard
`CancellationError`.

Operational failures use `SwiftlyKitError`. It conforms to `LocalizedError` and
provides a user-facing description. Common control-flow errors include:

- `dependencyResolutionRequired`
- `developerToolsUnavailable`
- `commandLineToolsInstallationRequestFailed`
- `executableProductSelectionRequired`
- `staleAssessment`
- `outputAlreadyExists`

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

## API overview

| Type | Purpose |
| --- | --- |
| `SwiftlyKit` | Provides the fast track, staged operations, and explicit Command Line Tools recovery. |
| `EnvironmentAssessment` | Describes the selected environment and required installations. |
| `LocalBuildEnvironment` | Binds later operations to one prepared package, target, toolchain, and SDK. |
| `BuildRequest` | Selects one product and its build options. |
| `BuildTarget`, `LinuxArchitecture` | Select the Linux architecture. |
| `BuildConfiguration` | Selects a debug or release build. |
| `ToolchainSelection`, `SwiftVersion` | Select an automatic or exact official stable Swift release. |
| `ExecutableProduct` | Identifies an executable product reported by SwiftPM. |
| `SwiftlyKitEvent`, `EventHandler` | Report progress and delegated command output. |
| `SwiftlyKitError` | Reports typed operational failures. |

## Development

Run the test suite from the repository root:

```sh
swift test
```

Run the real-system cross-compilation acceptance test explicitly on a prepared
host. It uses Triple's dependency-free fixture and never authorizes installation:

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

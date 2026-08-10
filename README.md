# SwiftlyKit

SwiftlyKit is a lightweight Swift library for building statically linked Linux
executables from a local Swift package on Apple-silicon macOS.

It delegates package behavior to SwiftPM and toolchain management to Swiftly.
SwiftlyKit adds the orchestration needed to select and prepare an exact official
Swift toolchain and Static Linux SDK, run the build, and verify the resulting ELF
executable.

## Usage

```swift
import Foundation
import SwiftlyKit

let packageRoot = URL(filePath: "/path/to/package")

// Prepares the environment and builds the package's sole executable for x86-64 Linux in release mode.
let executable = try await SwiftlyKit.build(packageRoot)
```

Specify a product, target, or configuration only when the defaults do not fit:

```swift
let executable = try await SwiftlyKit.build(
    packageRoot,
    product: "MyTool",
    for: .linux(.arm64),
    configuration: .debug
)
```

Use the staged API when installations or dependency resolution require separate authorization:

```swift
let kit = SwiftlyKit()

// Read-only: describes the exact environment and any required installations.
let assessment = try await kit.assess(packageRoot, for: .linux(.arm64))

// Explicitly authorizes only the installations described by the assessment.
// This call is still required when assessment.requiresInstallation is false.
let environment = try await kit.prepare(assessment) { event in
    // Update a UI or write command output.
}

// The prepared capability already carries the package and target context.
let products = try await kit.executableProducts(using: environment)
let request = BuildRequest(products[0], configuration: .release)

do {
    let executable = try await kit.build(request, using: environment)
} catch SwiftlyKitError.dependencyResolutionRequired {
    try await kit.resolveDependencies(using: environment)
    let executable = try await kit.build(request, using: environment)
}
```

## Guarantees

- Assessment is read-only; staged preparation and dependency resolution are explicit.
- The static fast track authorizes required preparation and dependency resolution in one operation.
- SwiftlyKit uses exact official stable Swift toolchains and matching SDKs.
- Staged builds never resolve dependencies automatically.
- Returned executables are verified static ELF64 files for the requested architecture.
- Mutating operations on one `SwiftlyKit` value are serialized and cancellable.
- Process, network, filesystem, and test seams remain internal.

Build-specific environment values are passed through, except SwiftlyKit protects
the home and Swiftly installation variables needed to preserve the prepared
toolchain. An explicit output destination is published atomically and is never
allowed to replace an existing item.

SwiftlyKit 0.1.0 requires Apple-silicon macOS 13 or later, Swiftly 1.0 or later
(installed automatically only with authorization), and an active macOS SDK from
Xcode or Command Line Tools.

For implementation structure, see [Architecture](Documentation/Architecture.md).
The complete release contract is [MVP 0.1.0](Documentation/MVP-0.1.0.md).

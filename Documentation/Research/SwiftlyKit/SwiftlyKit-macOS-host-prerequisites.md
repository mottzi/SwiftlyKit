# SwiftlyKit: macOS Host Prerequisites

**Target:** SwiftlyKit 0.1.0's native macOS Swiftly/SwiftPM architecture

**Reference date:** 6 August 2026

**Status:** Decision, amended 10 August 2026

## Question

Can SwiftlyKit honestly promise native macOS Swiftly/SwiftPM cross-compilation
while saying that Xcode and Apple Command Line Tools are not prerequisites?

## Decision

**No. The contradiction is real for the complete 0.1.0 product promise, but it
is narrower than “Swiftly cannot exist without CLT.”** SwiftlyKit can detect or
install Swiftly and perform its own textual assessment work without Apple
developer tools. It cannot prepare a *usable* macOS Swift toolchain and then run
SwiftPM package operations without a selected developer directory that provides
a usable macOS SDK and its supporting tools.

Full Xcode remains optional. The smallest ordinary prerequisite is Apple's
standalone Command Line Tools; an installed Xcode selected for command-line use
can satisfy the same host-SDK requirement. Swift.org likewise says Xcode is not
required to install or use an open-source toolchain, while warning that SwiftPM
functionality can be limited without it. That statement does not promise that a
macOS SDK is unnecessary.
[Swift.org: macOS package installer](https://www.swift.org/install/macos/package_installer/),
[Apple: installing the Command Line Tools](https://developer.apple.com/documentation/xcode/installing-the-command-line-tools)

The narrowest honest 0.1.0 resolution is therefore:

1. Replace “Xcode and Apple Command Line Tools: not SwiftlyKit prerequisites”
   with “Full Xcode is not required; a usable macOS SDK from the active Xcode or
   Command Line Tools developer directory is required.”
2. Make that SDK an assessed host precondition. If it is absent, fail assessment
   with an actionable typed host-prerequisite error; recheck it before any
   preparation mutation. Do not describe CLT as a component that SwiftlyKit can
   prepare. The read-only probe should require
   `/usr/bin/xcrun --show-sdk-path --sdk macosx` to succeed and return a nonempty
   SDK path, matching Swiftly and SwiftPM's own discovery.
   [Swiftly SDK probe](https://github.com/swiftlang/swiftly/blob/8e759540b22a1d58e592da96b7c1de058c360a8f/Sources/MacOSPlatform/MacOS.swift#L49-L75),
   [SwiftPM SDK discovery](https://github.com/swiftlang/swift-package-manager/blob/5f6969f5b083b4415632114d4897c6f820761a7f/Sources/PackageModel/SwiftSDKs/SwiftSDK.swift#L577-L595)
3. Keep Apple developer-tool installation and selection outside deterministic
   environment preparation. SwiftlyKit may expose an explicit recovery operation
   that invokes `xcode-select --install`, returns when macOS accepts the request,
   and leaves the system dialog, license acceptance, installation completion,
   and any developer-directory selection to the user. SwiftlyKit does not
   request administrator privileges.
4. Do not adopt Triple's Linux VM appliance for 0.1.0. That would remove the
   host SDK dependency, but it would replace the MVP's intentionally lightweight
   native-Swiftly architecture rather than correct its prerequisite statement.

This changes one host precondition and its failure handling. It does not require
a new build backend, private toolchain state, or a broader public workflow.

## Current upstream baseline

At the reference date, Swiftly 1.1.3 is the latest official Swiftly release and
Swift 6.3.3 is the latest official stable Swift release. The findings below use
Swiftly 1.1.3 and the SwiftPM source tagged for Swift 6.3.3; current Swiftly
`main` is called out separately where its unreleased behavior differs.
[Swiftly 1.1.3 release](https://github.com/swiftlang/swiftly/releases/tag/1.1.3),
[Swift 6.3.3 release](https://github.com/swiftlang/swift/releases/tag/swift-6.3.3-RELEASE)

The current sources were also checked: Swiftly `main` at `2192e23` identifies
itself as unreleased 1.3.0-dev, and SwiftPM `main` at `1ae8dbb` retains the same
macOS host-SDK discovery and failure behavior used by 6.3.3.
[current Swiftly commit](https://github.com/swiftlang/swiftly/commit/2192e233945870201e242af637cdc93f858dcca8),
[current Swiftly version](https://github.com/swiftlang/swiftly/blob/2192e233945870201e242af637cdc93f858dcca8/Sources/SwiftlyCore/SwiftlyCore.swift#L1-L5),
[current SwiftPM host SDK discovery](https://github.com/swiftlang/swift-package-manager/blob/1ae8dbb11290b4f49d2d573f1f126d65f9dfdf7a/Sources/PackageModel/SwiftSDKs/SwiftSDK.swift#L543-L632)

## Requirement boundary

| Operation | Host macOS SDK / CLT needed? | Reason |
|---|---:|---|
| Load SwiftlyKit; validate paths; read `swift-tools-version` and `.swift-version` as text | No | These are SwiftlyKit file operations and do not compile or execute `Package.swift`. This is also the MVP's specified assessment approach. [MVP: environment assessment](../../MVP-0.1.0.md#environment-assessment) |
| Request Apple's interactive Command Line Tools installer | No | The explicit recovery operation invokes the system-provided `/usr/bin/xcode-select --install` entry point. It only requests the dialog and does not imply that the user completed installation. [Apple: installing the Command Line Tools](https://developer.apple.com/documentation/xcode/installing-the-command-line-tools) |
| Locate Swiftly and read its version or installed stable-toolchain state without executing a toolchain | No | Released Swiftly's macOS platform declares no prerequisites for Swiftly itself, and its `list` command reads the Swiftly configuration rather than launching the compiler. [Swiftly 1.1.3: macOS Swiftly prerequisite](https://github.com/swiftlang/swiftly/blob/8e759540b22a1d58e592da96b7c1de058c360a8f/Sources/MacOSPlatform/MacOS.swift#L45-L47), [Swiftly 1.1.3: `list`](https://github.com/swiftlang/swiftly/blob/8e759540b22a1d58e592da96b7c1de058c360a8f/Sources/Swiftly/List.swift#L44-L67) |
| Install the Swiftly package and initialize it with `--skip-install` | No | The official package is installed into the current user's home. Swiftly initialization calls a platform prerequisite that is empty on macOS, and `--skip-install` bypasses toolchain installation. [Swift.org: install Swiftly on macOS](https://www.swift.org/install/macos/swiftly/), [Swiftly 1.1.3: initialization](https://github.com/swiftlang/swiftly/blob/8e759540b22a1d58e592da96b7c1de058c360a8f/Sources/Swiftly/Init.swift#L42-L45), [Swiftly 1.1.3: skip toolchain installation](https://github.com/swiftlang/swiftly/blob/8e759540b22a1d58e592da96b7c1de058c360a8f/Sources/Swiftly/Init.swift#L269-L275) |
| Install a macOS Swift toolchain with released Swiftly 1.1.3 | Yes in the released implementation | Before downloading, Swiftly calls its platform prerequisite check. On macOS that calls `/usr/bin/xcrun --show-sdk-path --sdk macosx`; the process helper throws on a nonzero result, so an absent SDK aborts the released install path. [Swiftly 1.1.3: install preflight](https://github.com/swiftlang/swiftly/blob/8e759540b22a1d58e592da96b7c1de058c360a8f/Sources/Swiftly/Install.swift#L261-L270), [Swiftly 1.1.3: macOS SDK check](https://github.com/swiftlang/swiftly/blob/8e759540b22a1d58e592da96b7c1de058c360a8f/Sources/MacOSPlatform/MacOS.swift#L49-L75), [Swiftly 1.1.3: nonzero process result throws](https://github.com/swiftlang/swiftly/blob/8e759540b22a1d58e592da96b7c1de058c360a8f/Sources/SwiftlyCore/Platform.swift#L297-L331) |
| Install a Static Linux SDK with `swift sdk install` | Yes | Every Swift SDK subcommand first constructs the host `UserToolchain` from `SwiftSDK.hostSwiftSDK`; on macOS, host SDK discovery uses `SDKROOT`/`SWIFTPM_SDKROOT_*` or runs `xcrun --sdk macosx --show-sdk-path` and throws if no default SDK is found. [SwiftPM 6.3.3: Swift SDK command setup](https://github.com/swiftlang/swift-package-manager/blob/5f6969f5b083b4415632114d4897c6f820761a7f/Sources/SwiftSDKCommand/SwiftSDKSubcommand.swift#L58-L75), [SwiftPM 6.3.3: host SDK discovery](https://github.com/swiftlang/swift-package-manager/blob/5f6969f5b083b4415632114d4897c6f820761a7f/Sources/PackageModel/SwiftSDKs/SwiftSDK.swift#L577-L595) |
| Evaluate `Package.swift`, including product discovery and dependency resolution | Yes | SwiftPM compiles the manifest for the macOS host, passes the host SDK to the compiler, then runs the resulting host executable. [SwiftPM 6.3.3: host target and manifest compilation](https://github.com/swiftlang/swift-package-manager/blob/5f6969f5b083b4415632114d4897c6f820761a7f/Sources/PackageLoading/ManifestLoader.swift#L747-L829), [SwiftPM 6.3.3: execute compiled manifest](https://github.com/swiftlang/swift-package-manager/blob/5f6969f5b083b4415632114d4897c6f820761a7f/Sources/PackageLoading/ManifestLoader.swift#L831-L909), [SwiftPM 6.3.3: pass host SDK](https://github.com/swiftlang/swift-package-manager/blob/5f6969f5b083b4415632114d4897c6f820761a7f/Sources/PackageLoading/ManifestLoader.swift#L950-L970) |
| Build with the Static Linux SDK | Yes | The target SDK supplies Linux Musl headers, libraries, and target configuration, but SwiftPM still performs the preceding macOS-hosted manifest work. Swift.org says the Static Linux SDK works from platforms supported by Swift and SwiftPM; it does not replace that platform's host SDK. [Swift.org: Static Linux SDK](https://www.swift.org/documentation/articles/static-linux-getting-started.html) |

## Swiftly release-versus-source nuance

The earlier Triple research is directionally correct for SwiftlyKit's usable
environment, but “toolchain installation requires CLT” needs version precision.

Released Swiftly 1.1.3 uses a throwing `xcrun` helper in its macOS preflight, so
failure to locate the macOS SDK stops installation before download. Current
unreleased Swiftly `main` instead captures `xcrun`'s termination status, prints
a warning, returns, and can continue placing the toolchain package. It still
states that the macOS SDK is required for the toolchain to work correctly.
[Swiftly 1.1.3 behavior](https://github.com/swiftlang/swiftly/blob/8e759540b22a1d58e592da96b7c1de058c360a8f/Sources/MacOSPlatform/MacOS.swift#L49-L75),
[current Swiftly source at `2192e23`](https://github.com/swiftlang/swiftly/blob/2192e233945870201e242af637cdc93f858dcca8/Sources/MacOSPlatform/MacOS.swift#L52-L83)

That unreleased relaxation does not make the MVP CLT-free. Current Swiftly
source derives `SDKROOT` with `xcrun` when running a selected toolchain. For a
nonstandard toolchain directory it is even more explicit: it requires
`/Library/Developer/CommandLineTools` and reuses that installation's SDKs and
`libxcrun.dylib` in a compatibility developer directory.
[current Swiftly source: selected-toolchain environment](https://github.com/swiftlang/swiftly/blob/2192e233945870201e242af637cdc93f858dcca8/Sources/MacOSPlatform/MacOS.swift#L265-L342)

SwiftlyKit's promise is not merely to place a `.xctoolchain` on disk. It must
return a `LocalBuildEnvironment` that can install the matching Static Linux SDK,
evaluate a manifest, resolve dependencies, and build. Those SwiftPM operations
still require the host macOS SDK even if a future Swiftly release permits the
preceding package extraction to finish.

## Why the Static Linux SDK does not close the gap

`Package.swift` is executable host code, not inert target configuration. On a
macOS SwiftPM process it is compiled as a macOS executable and run before the
package graph and build plan exist. The Static Linux SDK is then used for target
compilation and linking; it cannot replace the SDK needed to create and run the
macOS manifest executable.
[SwiftPM 6.3.3 manifest loader](https://github.com/swiftlang/swift-package-manager/blob/5f6969f5b083b4415632114d4897c6f820761a7f/Sources/PackageLoading/ManifestLoader.swift#L747-L909),
[Swift.org: Static Linux SDK cross-compilation](https://www.swift.org/documentation/articles/static-linux-getting-started.html#your-first-statically-linked-linux-program)

Therefore the package-specific caveat in the MVP is insufficient. Plugins and
C/C++ host tools can add further requirements, but the macOS SDK is already a
baseline requirement of SwiftlyKit's own native SwiftPM workflow, even for a
minimal pure-Swift executable package.

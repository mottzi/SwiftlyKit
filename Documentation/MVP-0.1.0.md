# SwiftlyKit 0.1.0 MVP Specification

## Status

This document defines the functionality required for the SwiftlyKit 0.1.0
release. It is the product boundary for the first implementation.

SwiftlyKit 0.1.0 is intentionally small. It delegates Swift package behavior to
SwiftPM and toolchain management to Swiftly. It adds only the orchestration,
explicit authorization boundary, process control, and output verification needed
to cross-compile a local Swift package reliably.

Normative terms such as **must**, **must not**, **should**, and **may** describe
release requirements.

## Product promise

SwiftlyKit is a high-level Swift library that prepares an official Swift
cross-compilation environment and builds one executable product from a trusted
local Swift package root.

For 0.1.0, SwiftlyKit:

- runs on Apple-silicon macOS 13 or later with an active developer directory
  providing a usable macOS SDK;
- supports unsandboxed macOS applications and command-line tools;
- accepts a local package root containing `Package.swift`;
- targets statically linked Linux Musl executables for ARM64 or x86-64;
- uses an exact official stable Swift toolchain and its matching official Static
  Linux SDK;
- returns the URL of one verified executable.

## Design principles

### Lightweight

The public API must remain small and task-oriented. SwiftlyKit must not expose
its process runner, network client, file-system seams, provider protocols, or
other test infrastructure.

SwiftlyKit must not contain a database, retained build history, artifact library,
ownership ledger, log store, package compatibility analyzer, or source watcher.

### Explicit mutation

Environment assessment is read-only. Installation occurs only when the consumer
passes an assessment to `prepare(_:)`.

Requesting Apple's interactive Command Line Tools installer is a separate,
explicit recovery operation. It is never triggered by assessment, preparation,
or building and does not claim that installation completed.

Dependency resolution is also explicit. An ordinary build must never install
environment components or resolve package dependencies.

### Official tools and shared state

SwiftlyKit uses the current user's official Swiftly and SwiftPM locations. It
does not create a private toolchain installation.

SwiftlyKit must never:

- modify a shell profile;
- select or change the user's default Swift toolchain;
- invoke `swiftly use`;
- update or replace an existing Swiftly installation;
- remove Swiftly, a toolchain, or an SDK.

SwiftlyKit may invoke `xcode-select --install` only from the consumer's explicit
call to `requestCommandLineToolsInstallation()`. That operation requests Apple's
system dialog; it does not accept the license, wait for installation, install
Xcode, or select an active developer directory.

### Swift concurrency

All long-running operations use Swift concurrency. Public operations are
`async throws` functions. They may accept one optional, awaited, `@Sendable`
event handler.

SwiftlyKit uses `swift-subprocess` 1.x internally for process execution,
streaming output, structured cancellation, bounded collection, and process-group
teardown. The process implementation is not public API.

## Supported host and targets

### Host

- Architecture: Apple silicon only.
- Operating system: macOS 13 or later.
- App Sandbox: unsupported.
- Full Xcode: optional.
- macOS SDK: required from either the selected Xcode installation or Apple's
  standalone Command Line Tools.

SwiftlyKit must return `unsupportedHost` before mutation on an Intel Mac or an
unsupported macOS release. It must return `developerToolsUnavailable` before
mutation when `/usr/bin/xcrun --sdk macosx --show-sdk-path` does not identify a
usable SDK. The consumer may then explicitly call
`requestCommandLineToolsInstallation()` to request Apple's interactive installer.
The user remains responsible for completing installation or selecting existing
developer tools before retrying assessment.

A package can still have its own host-tool requirements. For example, a package
plugin or C++ host tool can require Apple developer components. SwiftlyKit does
not predict or install those requirements; it reports the resulting SwiftPM
failure.

### Build targets

```swift
public enum BuildTarget: Sendable, Hashable {
    case linux(LinuxArchitecture)
}

public enum LinuxArchitecture: Sendable, Hashable {
    case arm64
    case x86_64
}
```

The matching Swift SDK selectors are:

- ARM64: `aarch64-swift-linux-musl`
- x86-64: `x86_64-swift-linux-musl`

SwiftlyKit 0.1.0 does not build macOS executables. The API uses general names
such as `BuildTarget` and `BuildRequest` so a later implementation can add a
macOS target. No dormant macOS implementation is required in 0.1.0, and no API
compatibility promise applies before the library has real users.

## Public API shape

The following declarations describe the intended API shape. Exact documentation
wording and accessors may be refined during implementation, but the workflow and
capabilities must remain within this specification.

```swift
public struct SwiftlyKit: Sendable {
    public init()

    public func assess(
        _ packageRoot: URL,
        for target: BuildTarget,
        toolchain: ToolchainSelection = .automatic
    ) async throws -> EnvironmentAssessment

    public func prepare(
        _ assessment: EnvironmentAssessment,
        onEvent: EventHandler? = nil
    ) async throws -> LocalBuildEnvironment

    public func executableProducts(
        using environment: LocalBuildEnvironment
    ) async throws -> [ExecutableProduct]

    public func resolveDependencies(
        using environment: LocalBuildEnvironment,
        onEvent: EventHandler? = nil
    ) async throws

    public func build(
        _ request: BuildRequest,
        using environment: LocalBuildEnvironment,
        onEvent: EventHandler? = nil
    ) async throws -> URL
}

public typealias EventHandler = @Sendable (SwiftlyKitEvent) async -> Void
```

`SwiftlyKit()` is the only public initializer. Production paths and internal
implementations are not configurable through a global public configuration
object. Request-specific choices belong to `BuildRequest`.

## Core values

### Toolchain selection

```swift
public enum ToolchainSelection: Sendable, Hashable {
    case automatic
    case exact(SwiftVersion)
}
```

`SwiftVersion` is a strongly typed, comparable semantic version for an official
stable Swift release. The public API does not accept arbitrary Swiftly selector
strings, snapshots, or development branches.

### Environment assessment

`EnvironmentAssessment` is an immutable, `Sendable` value. It contains enough
information for a consumer to explain and authorize preparation:

- the canonical package root;
- the package's Swift tools version;
- the selected exact Swift release;
- the selected exact Static Linux SDK identity and version;
- whether a compatible Swiftly installation is available;
- whether the selected toolchain is available;
- whether the selected SDK is available;
- the exact components that `prepare(_:)` will install;
- whether installation is required.

The assessment does not contain a generic diagnostics collection or a
speculative download-size estimate.

### Local build environment

`LocalBuildEnvironment` is an immutable, `Sendable` capability value returned by
`prepare(_:)`. It binds later operations to the canonical package root, build
target, exact Swiftly executable, stable Swift release, and matching Static
Linux SDK. Callers establish those invariants once during assessment instead of
repeating them in every later operation.

It exposes displayable version and SDK identity information. Internal paths and
provider objects do not become public API.

### Executable product

`ExecutableProduct` is an immutable, `Sendable`, `Hashable` value with the
product name needed by SwiftPM. Product discovery returns only executable
products.

### Build request

The expressive initializer is:

```swift
public struct BuildRequest: Sendable {
    public init(
        _ product: ExecutableProduct,
        configuration: BuildConfiguration = .debug,
        scratchDirectory: URL? = nil,
        output: URL? = nil,
        strip: Bool = false,
        environment: [String: String] = [:]
    )
}

public enum BuildConfiguration: Sendable, Hashable {
    case debug
    case release
}
```

There are no arbitrary SwiftPM arguments, test settings, traits, job-count
settings, compiler flags, or linker flags in 0.1.0.

## Consumer workflow

```swift
let kit = SwiftlyKit()
let packageRoot = URL(filePath: "/path/to/package")
let target: BuildTarget = .linux(.arm64)

let assessment = try await kit.assess(packageRoot, for: target)

if assessment.requiresInstallation {
    // The consumer presents the exact required changes and gets authorization.
}

// Preparation is always required to obtain the capability used by later calls.
let environment = try await kit.prepare(assessment) { event in
    // Optional UI or command-line reporting.
}

let products = try await kit.executableProducts(using: environment)

let request = BuildRequest(
    products[0],
    configuration: .release
)

let executable = try await kit.build(request, using: environment) { event in
    // Optional UI or command-line reporting.
}
```

If a build reports unresolved dependencies, resolution is a separate authorized
operation:

```swift
do {
    return try await kit.build(request, using: environment)
} catch SwiftlyKitError.dependencyResolutionRequired {
    try await kit.resolveDependencies(
        using: environment
    )

    return try await kit.build(request, using: environment)
}
```

## Environment assessment

Assessment must not modify the file system outside ordinary temporary network
or decoding behavior, invoke an installer, install a toolchain or SDK, resolve
dependencies, or change Swiftly selection.

Assessment performs these functions:

1. Validate the supported host and active macOS SDK.
2. Validate and canonicalize the package root.
3. Read the `swift-tools-version` declaration from `Package.swift` without
   evaluating the manifest.
4. Read a `.swift-version` preference when present.
5. Detect a usable Swiftly 1.0 or later installation from official locations and
   inherited Swiftly location variables.
6. Read the official Swift.org stable release catalog.
7. Inspect installed stable Swiftly toolchains.
8. Inspect matching installed Static Linux SDKs when possible.
9. Resolve the selection to an exact stable Swift release and SDK pair.

### Automatic selection order

`.automatic` uses this order:

1. A valid compatible stable `.swift-version` preference, resolved to an exact
   official release with a matching Static Linux SDK.
2. The newest already-installed exact toolchain and matching SDK compatible with
   the package tools version and requested architecture.
3. The newest compatible official stable Swift release with a matching official
   Static Linux SDK supporting the requested architecture.

An `.exact` selection must be compatible with the package tools version and must
have an official matching Static Linux SDK for the requested architecture.

SwiftlyKit rejects snapshot selectors, custom SDKs, and releases without a
matching official SDK.

### Swiftly compatibility

If Swiftly is absent, assessment may describe installation of the current
official Swiftly package as a required preparation component.

If Swiftly is present but older than 1.0, assessment fails with
`incompatibleSwiftly`. SwiftlyKit does not update or replace it.

## Environment preparation

`prepare(_:)` is the only operation that may install Swiftly, a toolchain, or an
SDK.

Before mutation, preparation must revalidate the supported host and active
macOS SDK, then verify that `Package.swift` and `.swift-version` still match the
assessment. Missing developer tools fail with `developerToolsUnavailable`; an
input mismatch fails with `staleAssessment`. SwiftlyKit must not silently select
different components.

If all components are ready, `prepare(_:)` returns the exact
`LocalBuildEnvironment` without mutation.

### Installing Swiftly

When the accepted assessment requires Swiftly, preparation:

1. downloads the official macOS Swiftly package over HTTPS;
2. requires a successful HTTP response;
3. stages it in a unique temporary location;
4. verifies the package signature, official Swift Open Source installer identity,
   and Apple trust;
5. installs it for `CurrentUserHomeDirectory`;
6. initializes Swiftly with no profile modification and no default toolchain
   installation or selection.

The initialization must use the official equivalents of:

```text
swiftly init --no-modify-profile --skip-install --quiet-shell-followup --assume-yes
```

### Installing a toolchain

Preparation installs only the selected exact stable release. It uses Swiftly's
download verification and noninteractive mode. It must not pass `--use` or
otherwise change the default toolchain.

### Installing the Static Linux SDK

Preparation invokes SwiftPM through the selected exact Swiftly toolchain. It
installs the official SDK URL with its published checksum. Toolchain and SDK
versions must match exactly.

### Stateless behavior

SwiftlyKit persists no preparation journal or ownership record. After failure or
cancellation, a later assessment redetects official tool state. SwiftlyKit does
not manipulate Swiftly's private registry or lock-file formats.

## Product discovery

`executableProducts(using:)` evaluates the manifest with the exact prepared
toolchain, using SwiftPM's package description output. It does not install
components or resolve dependencies.

The operation returns executable product names only. Manifest evaluation and
unsupported tools-version failures are typed errors, not embedded successful
diagnostics.

Reliable product discovery requires a prepared compatible toolchain. SwiftlyKit
does not implement its own Swift manifest parser.

## Dependency resolution

`resolveDependencies(using:onEvent:)`:

- uses the exact prepared Swift toolchain;
- runs SwiftPM's explicit package resolution operation;
- may access the network using the inherited process environment;
- may create or update `Package.resolved` in the package root;
- does not build the executable.

An ordinary build disables automatic resolution. A package without external
dependencies does not require `Package.resolved`. SwiftPM remains the authority
on whether dependency state is usable. SwiftlyKit does not duplicate
`Package.resolved` schema validation.

When resolution is needed, build fails with `dependencyResolutionRequired` and
does not resolve automatically.

## Build workflow

A build performs these functions:

1. Validate the Build request and revalidate the package and tools bound to the
   supplied Local build environment.
2. Create a temporary SDK search directory containing only a link to the exact
   selected Static Linux SDK.
3. Invoke `swift build` through the exact Swiftly toolchain.
4. Select the requested Linux Musl SDK, product, and debug or release
   configuration.
5. Disable automatic dependency resolution.
6. Locate the exact executable produced by SwiftPM.
7. Reject a product that requires a SwiftPM runtime resource bundle.
8. Verify the executable.
9. Strip and reverify it only when explicitly requested.
10. Atomically publish it when an output URL was supplied.
11. Return the final executable URL.

SwiftlyKit does not run package tests before or after the build.

### Scratch storage

When `scratchDirectory` is `nil`, SwiftlyKit uses the package root's normal
`.build` directory and lets SwiftPM manage it.

When the caller supplies `scratchDirectory`, SwiftlyKit passes it to SwiftPM.

SwiftlyKit must:

- never remove the package root's `.build` directory;
- never remove a caller-provided scratch directory;
- remove only its own temporary exact-SDK search directory;
- leave the produced executable in scratch storage when no output URL is given.

A later build using the same scratch storage may replace the executable. A
consumer that needs a durable output supplies `output`.

### Environment variables

Build subprocesses inherit the consumer process environment. `BuildRequest`
environment entries add or replace values for the build invocation.

SwiftlyKit may apply required overrides that preserve the assessed exact
toolchain and SDK. Required correctness overrides take precedence over request
additions.

Environment values are never included in events or error descriptions.

### Output publication

`output` is an optional exact file URL.

- If `output` is `nil`, build returns the executable in scratch storage.
- If `output` is present, SwiftlyKit copies the verified executable to a unique
  sibling temporary file and atomically publishes it at that URL.
- SwiftlyKit refuses to replace an existing file and throws
  `outputAlreadyExists`.
- SwiftlyKit does not create an artifact bundle, archive, manifest, checksum
  file, SBOM copy, or retained metadata record.

### Stripping

Stripping defaults to `false` for both debug and release configurations.

When `strip` is `true`, SwiftlyKit uses the exact toolchain's `llvm-objcopy` to
strip the executable. A strip failure fails the build. SwiftlyKit verifies the
result again after stripping.

SwiftlyKit does not expose a general operation for stripping arbitrary files.

## Executable verification

A successful build must prove that the output:

- is a regular file;
- has executable permissions;
- is a little-endian ELF64 executable;
- declares the requested ARM64 or x86-64 machine architecture;
- contains at least one loadable segment;
- does not contain a dynamic interpreter segment;
- does not declare required dynamic libraries.

Verification reads ELF structures directly or through an equivalently reliable
internal implementation. SwiftlyKit must not treat the text output of the host's
`file` command as sufficient proof.

If the product requires runtime resources outside the executable, verification
fails with an unsupported-product error. SwiftlyKit 0.1.0 promises one portable
file, not an executable plus resource bundle.

## Events and progress

The optional event handler receives one shared event type:

```swift
public enum SwiftlyKitEvent: Sendable {
    case progress(OperationProgress)
    case output(CommandOutput)
}
```

`OperationProgress` identifies the current operation, component or activity and
human-readable detail. SwiftlyKit does not invent fractional or elapsed-time
progress when its delegated tools do not report trustworthy measurements.

`CommandOutput` identifies standard output or standard error and contains the
text chunk produced by the subprocess. SwiftlyKit awaits the event handler, which
provides natural backpressure without an `AsyncStream` buffer.

Event handling is optional. SwiftlyKit retains no Build log. A consumer that
wants a Build log stores received events itself.

## Concurrency and cancellation

`SwiftlyKit` is a small `Sendable` value backed by private coordinated state.

One instance allows read-only assessment and product discovery to run
concurrently. It serializes mutating operations:

- Environment preparation;
- dependency resolution;
- builds.

A second mutating operation waits for the current mutating operation.

Cancelling the calling task requests cancellation of the complete subprocess
group. SwiftlyKit performs owned temporary cleanup and throws Swift's standard
`CancellationError`. Cancellation is not wrapped in `SwiftlyKitError`.

Ending or omitting event observation does not detach a running subprocess.

## Errors

SwiftlyKit exposes one typed `SwiftlyKitError` family with actionable context.
It covers at least:

- invalid package root;
- unsupported host;
- unavailable macOS developer tools;
- failed Command Line Tools installation request;
- unsupported or malformed tools version;
- incompatible Swiftly;
- Swiftly installation failure;
- network failure;
- integrity or signature failure;
- unavailable compatible stable release or SDK;
- stale assessment;
- dependency resolution required or failed;
- executable product not found;
- unsupported product resources;
- SwiftPM build failure;
- strip failure;
- executable verification failure;
- output already exists;
- output publication failure.

Errors may contain the executed program, redacted arguments, exit status, and a
bounded excerpt of process output. They must not contain environment values,
credentials, complete unbounded output, or a retained log path.

Underlying implementation errors remain available for debugging where Swift's
error conventions permit, but internal provider and process types are not public
API.

## Security model

SwiftlyKit is not a package security sandbox. Consumers must supply a trusted
package root. SwiftPM evaluates `Package.swift` and can execute package plugins
with the consumer process's user permissions.

All official downloads use HTTPS. Swiftly installer trust, Swiftly toolchain
verification, and published Static Linux SDK checksums are mandatory.

SwiftlyKit does not request administrator privileges, Full Disk Access, or App
Sandbox exceptions. Its explicit Command Line Tools recovery operation requests
Apple's system installer, where the user controls license acceptance and
installation. SwiftlyKit does not install Xcode or select developer tools.

## Explicit non-goals for 0.1.0

The release does not include:

- Intel Mac hosts;
- sandboxed macOS consumers or Mac App Store support;
- native macOS executable builds;
- Linux-hosted SwiftlyKit;
- Windows, WebAssembly, Android, or custom Swift SDK targets;
- Swift snapshots or development branches;
- repository cloning, branches, revisions, or source acquisition;
- building all executable products in one request;
- package tests;
- automatic dependency resolution during build;
- arbitrary SwiftPM, compiler, or linker arguments;
- automatic Swiftly upgrades;
- unattended Apple developer-tool installation or any developer-tool selection;
- shell-profile or default-toolchain changes;
- private toolchain or SDK installations;
- toolchain or SDK deletion;
- environment ownership tracking;
- persistent preparation recovery state;
- source-tree fingerprints or file watching;
- retained builds, logs, artifacts, provenance, or export history;
- runtime resource bundle packaging;
- signing, notarization, archiving, or deployment;
- executing the produced Linux binary.

## Release acceptance criteria

SwiftlyKit 0.1.0 is functionally ready when automated tests and controlled
acceptance fixtures prove all of the following:

1. Assessment of the same unchanged package root is repeatable and read-only.
2. A missing usable macOS SDK fails with `developerToolsUnavailable` before any
   environment mutation or automatic installer request.
3. An explicit Command Line Tools installation request invokes only
   `/usr/bin/xcode-select --install`, returns after the request is accepted, and
   does not run when the active SDK is already usable.
4. Automatic selection follows the specified precedence and resolves an exact
   stable toolchain and matching SDK.
5. Exact selection rejects incompatible releases, snapshots, and SDK mismatches.
6. A missing Swiftly installation produces an explicit preparation requirement.
7. Authorized preparation installs official Swiftly without modifying shell
   profiles or selecting a default toolchain.
8. Preparation installs and uses only the selected exact toolchain and matching
   checksummed SDK.
9. An existing compatible Local build environment is reused without mutation.
10. An existing Swiftly release older than 1.0 is rejected without replacement.
11. A changed `Package.swift` or `.swift-version` makes an assessment stale before
   preparation.
12. Product discovery returns the executable products from the exact prepared
    toolchain.
13. A dependency-free package builds without `Package.resolved`.
14. A package requiring resolution fails with `dependencyResolutionRequired`;
    explicit resolution followed by build succeeds.
15. ARM64 and x86-64 fixtures produce verified static ELF64 executables of the
    requested architecture.
16. The unstripped executable is returned by default in debug and release builds.
17. Explicit stripping uses the exact toolchain and returns a reverified
    executable; strip failure fails the operation.
18. A caller-selected output is published atomically, and an existing output is
    never replaced.
19. Products requiring runtime resource bundles are rejected.
20. Cancellation terminates the full subprocess tree and throws
    `CancellationError`.
21. Mutating operations on one `SwiftlyKit` instance are serialized.
22. Events stream without persisted logs, and errors contain only bounded,
    redacted process context.
23. SwiftlyKit creates no database, ownership journal, retained Build record, or
    Artifact bundle.

## Upstream references

- [Installing the Command Line Tools](https://developer.apple.com/documentation/xcode/installing-the-command-line-tools)
- [Getting Started with the Static Linux SDK](https://www.swift.org/documentation/articles/static-linux-getting-started.html)
- [Getting Started with Swiftly on macOS](https://www.swift.org/install/macos/swiftly/)
- [Swiftly](https://github.com/swiftlang/swiftly)
- [Swift Subprocess 1.0](https://github.com/swiftlang/swift-subprocess/releases/tag/1.0.0)

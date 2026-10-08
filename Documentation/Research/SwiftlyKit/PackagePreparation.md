# Fast package configuration with exact toolchain validation

Research date: 2026-10-08.

The configuration screen needs the root manifest's executable products. It does not need to resolve dependencies or prove that every dependency manifest compiles before the user can choose a product. Build must still perform those checks with the exact selected Swift compiler and an installed macOS SDK that actually works. The implementation now separates these responsibilities. SwiftPM does not guarantee a particular latency.

## Sources and scope

This investigation compared SwiftPM's `swift-6.3.3-RELEASE` tag at `5f6969f5b083b4415632114d4897c6f820761a7f` with `swift-6.4.0-RELEASE` at `18da3eb1e770679f6910890fbd52e95af53f67d2`. It also inspected Swift compiler tags `064859e41d68596f486c5d724401cb370f260409` and `b8189d766d86ad7fc8106787d6ce9e402f38dd72`, the pinned Deployer dependency manifest, and the installed SDK interfaces. Source claims below link to the source that owns the behavior. Recommendations are marked as design conclusions.

## Root configuration and dependency validation do different work

`swift package dump-package` loads only the workspace's root manifests and serializes the selected root manifest. It does not invoke the package graph loader. This is the existing command SwiftlyKit already decodes for products. [SwiftPM 6.3.3 `DumpPackage.run`](https://github.com/swiftlang/swift-package-manager/blob/5f6969f5b083b4415632114d4897c6f820761a7f/Sources/Commands/PackageCommands/DumpCommands.swift#L149-L176), [SwiftPM 6.4.0 implementation](https://github.com/swiftlang/swift-package-manager/blob/18da3eb1e770679f6910890fbd52e95af53f67d2/Sources/Commands/PackageCommands/DumpCommands.swift#L149-L176).

`swift package describe --type json` also avoids the dependency graph. It calls `workspace.loadRootPackage`, which constructs a root package model and examines its targets. Its implementation is identical between the two inspected tags. Replacing `dump-package` with `describe` adds no protection against a dependency manifest failure. [SwiftPM 6.3.3 `Describe.run`](https://github.com/swiftlang/swift-package-manager/blob/5f6969f5b083b4415632114d4897c6f820761a7f/Sources/Commands/PackageCommands/Describe.swift#L33-L48), [SwiftPM 6.4.0 `Describe.run`](https://github.com/swiftlang/swift-package-manager/blob/18da3eb1e770679f6910890fbd52e95af53f67d2/Sources/Commands/PackageCommands/Describe.swift#L33-L48).

`show-dependencies` calls `loadPackageGraph`. The workspace reloads its persisted state, resolves as required by the selected resolution policy, loads dependency manifests, and constructs the graph. Missing checkouts, graph errors, binary artifacts, and manifest compilation all belong to this phase. [SwiftPM `ShowDependencies.run`](https://github.com/swiftlang/swift-package-manager/blob/5f6969f5b083b4415632114d4897c6f820761a7f/Sources/Commands/PackageCommands/ShowDependencies.swift#L39-L49), [SwiftPM graph loading](https://github.com/swiftlang/swift-package-manager/blob/5f6969f5b083b4415632114d4897c6f820761a7f/Sources/Workspace/Workspace.swift#L987-L1064).

Design conclusion: publish products from root evaluation as configuration. A configuration permits starting a build workflow. It is not evidence that all dependencies can compile. Keep full graph validation inside the build workflow before actual compilation and output publication. An invalid dependency must still fail that workflow, even if root configuration succeeded.

## The 6.3.3 failure is a host manifest compiler problem

Deployer pins `swift-crypto` 4.5.0 at revision `1b6b2e274e85105bfa155183145a1dcfd63331f1`. That manifest uses the scoped declaration `import class Foundation.ProcessInfo`. [Pinned `swift-crypto` manifest](https://github.com/apple/swift-crypto/blob/1b6b2e274e85105bfa155183145a1dcfd63331f1/Package.swift#L25-L27).

SwiftPM compiles package manifests into host executables. On macOS its manifest compiler receives the selected host SDK through `-sdk`, then SwiftPM runs the compiled manifest. The Linux SDK does not remove this macOS compilation step. [SwiftPM manifest compilation and execution](https://github.com/swiftlang/swift-package-manager/blob/5f6969f5b083b4415632114d4897c6f820761a7f/Sources/PackageLoading/ManifestLoader.swift#L700-L943), [host SDK argument](https://github.com/swiftlang/swift-package-manager/blob/5f6969f5b083b4415632114d4897c6f820761a7f/Sources/PackageLoading/ManifestLoader.swift#L950-L970).

The locally installed SDK 27 Foundation and Darwin `arm64e-apple-macos.swiftinterface` headers contain the non-ignorable argument `-target-arch-variant arm64e.x1` and report interface compiler version 6.4. Swift 6.4 declares that compiler option. The inspected Swift 6.3.3 option table has no such declaration. [Swift 6.4 option declaration](https://github.com/swiftlang/swift/blob/b8189d766d86ad7fc8106787d6ce9e402f38dd72/include/swift/Option/Options.td#L1616-L1624), [Swift 6.3.3 option table](https://github.com/swiftlang/swift/blob/064859e41d68596f486c5d724401cb370f260409/include/swift/Option/Options.td#L1598-L1613).

These installed interface files are the direct evidence for the SDK contents, rather than a claim that every SDK 27 installation has identical headers:

- [Foundation SDK 27 interface](/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk/System/Library/Frameworks/Foundation.framework/Modules/Foundation.swiftmodule/arm64e-apple-macos.swiftinterface:3)
- [Darwin SDK 27 interface](/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk/usr/lib/swift/Darwin.swiftmodule/arm64e-apple-macos.swiftinterface:3)

The existing local regression test reproduces a dependency manifest with the scoped Foundation import. It requires Swift 6.3.3 and active SDK 27, checks recovery to installed SDK 26.5 while retaining Swift 6.3.3, repeats after caching, and edits the dependency manifest to require a new failure. [Local live regression](/Users/berken/Development/Swift/SwiftlyKit/Tests/SwiftlyKitTests/SwiftPM/LiveHostManifestCacheTests.swift), [current recovery implementation](/Users/berken/Development/Swift/SwiftlyKit/Sources/SwiftlyKit/SwiftPM/SwiftPM+Inspection.swift). The recovery was introduced by local commit `c2088fe21d55b307a4cff3c0b1ee5ccd37c86281`.

Design conclusion: retain observed SDK fallback with the exact compiler. Do not assume root success proves dependency compatibility. Do not silently select 6.4 when the user requests 6.3.3. The successful host SDK is part of the returned prepared environment and must propagate to resolution, graph inspection, plugins, macros, and build commands. Candidate version sorting can guide attempts; actual package evaluation must decide success.

## Retained caches can preserve the fix

SwiftPM's manifest key hashes package identity and location, manifest bytes, tools version, filtered environment values, its own version string, and extra manifest flags. Cache hits return evaluated manifest JSON. Only successful parsing reaches the cache write. The key does not directly hash the installed compiler executable or SDK directory contents. [SwiftPM manifest key](https://github.com/swiftlang/swift-package-manager/blob/5f6969f5b083b4415632114d4897c6f820761a7f/Sources/PackageLoading/ManifestLoader.swift#L1016-L1082), [successful manifest caching](https://github.com/swiftlang/swift-package-manager/blob/5f6969f5b083b4415632114d4897c6f820761a7f/Sources/PackageLoading/ManifestLoader.swift#L479-L583).

Filtering excludes known transient keys and credential variables; arbitrary environment keys remain cacheable. [SwiftPM environment filtering](https://github.com/swiftlang/swift-package-manager/blob/5f6969f5b083b4415632114d4897c6f820761a7f/Sources/Basics/Environment/Environment.swift#L281-L294), [excluded environment keys](https://github.com/swiftlang/swift-package-manager/blob/5f6969f5b083b4415632114d4897c6f820761a7f/Sources/Basics/Environment/EnvironmentKey.swift#L42-L65).

The Swift compiler separately resolves cached module output using the interface path, SDK path, and compiler invocation. It checks cached dependency size and modification time, or content hash, before accepting a module. This is a different cache from evaluated manifest JSON. [Swift cached module path](https://github.com/swiftlang/swift/blob/064859e41d68596f486c5d724401cb370f260409/lib/Frontend/ModuleInterfaceLoader.cpp#L2080-L2090), [cached dependency validation](https://github.com/swiftlang/swift/blob/064859e41d68596f486c5d724401cb370f260409/lib/Frontend/ModuleInterfaceLoader.cpp#L491-L522).

Design conclusion: retain compiler-managed module caching and scope SwiftPM manifest caching by installed compiler and SDK identity. Injecting a reserved identity marker into the environment changes SwiftPM's manifest key. A fresh random marker or random module-cache directory on every inspection defeats reuse and forces repeated work. If identity cannot be determined, disable manifest reuse for that operation. Cache isolation complements full validation; it cannot replace it.

## A root-only command can still wait on a build

Both root commands construct an active workspace. SwiftPM takes an exclusive lock on its scratch directory before doing so. The default lock waits behind another process using that scratch directory. This happens even when a command loads only the root manifest. [SwiftPM workspace construction](https://github.com/swiftlang/swift-package-manager/blob/5f6969f5b083b4415632114d4897c6f820761a7f/Sources/CoreCommands/SwiftCommandState.swift#L485-L498), [scratch directory locking](https://github.com/swiftlang/swift-package-manager/blob/5f6969f5b083b4415632114d4897c6f820761a7f/Sources/CoreCommands/SwiftCommandState.swift#L1143-L1192).

Design conclusion: configuration needs separate scratch storage from a running build. Do not use `--ignore-lock` against shared scratch storage. Separate scratch storage still shares safe compiler and manifest caches; it does not need a fresh module cache or dependency checkouts.

Reading package files and an already captured local inventory does not require SwiftlyKit's user-wide mutation lock. Root evaluation writes its own scratch and cache state, however, and must not race removal of the selected compiler. Graph resolution, SDK installation/removal, package cleanup, and output export remain mutations. Merely deleting the global gate would lose coordination guarantees. Use specific resource leases if changing coordination, and define ordering for operations requiring more than one resource. This is a design inference from SwiftPM's lock behavior and [SwiftlyKit's current gate](/Users/berken/Development/Swift/SwiftlyKit/Sources/SwiftlyKit/MutationGate.swift), not an upstream permission to run all SwiftPM commands concurrently.

## Cancellation and reuse need explicit ownership

Swift task cancellation is cooperative. Cancellation must reach the subprocess adapter and prevent an old selection from publishing into a new selection's UI state. The configured `swift-subprocess` implementation performs teardown on cancellation. Its final kill inherits process-group targeting from the explicit teardown sequence. [Subprocess cancellation handling](https://github.com/swiftlang/swift-subprocess/blob/1.0.0/Sources/Subprocess/Configuration.swift#L1351-L1403), [process-group teardown](https://github.com/swiftlang/swift-subprocess/blob/1.0.0/Sources/Subprocess/Teardown.swift#L185-L207).

Manifests can read `Context.environment`, their package directory, and Git information. Persisting a result solely by manifest path or package name can therefore reuse a different package configuration. [Manifest context interface](https://github.com/swiftlang/swift-package-manager/blob/5f6969f5b083b4415632114d4897c6f820761a7f/Sources/Runtimes/PackageDescription/Context.swift#L14-L41).

Design conclusion: a preparation session owns one request identity and one cancellation lifetime. Its root products are configuration data. Retain full graph evidence only within a bounded workflow and revalidate before use when relevant inputs change. Those inputs include compiler/SDK identity, manifest bytes at every graph root, `Package.resolved`, traits, effective environment, dependency locations, and resolver configuration. Arbitrary manifest access to external state makes a universal, permanent validation cache impossible. Leave SwiftPM authoritative at build time.

## Implemented configuration and build ownership

The new library entrypoint returns root products and the environment that evaluated them:

```swift
let configuration = try await kit.configurePackage(using: environment)
let product = try configuration.products.select("deployer")
let result = try await kit.build(
    BuildRequest(product),
    using: configuration.environment,
    dependencies: .resolveIfNeeded
)
```

`configurePackage` evaluates only the root manifest using a prepared installed compiler and isolated configuration scratch storage. It does not fetch a release catalog, install tools, resolve dependencies, or call the graph loader. Full inspection remains available through `inspectPackage`. Existing low-level callers retain the default requirement for already resolved dependencies; explicit resolution requires `.resolveIfNeeded`.

The app's `BuildOptions` owns the ordered discovery operation through one keyed SwiftUI task. Host checks, compatible choices, approved preparation, and root configuration share one generation identity. Discovery starts on package selection and overlaps the presentation animation. Controls become usable only after both finish. Cancelled or obsolete tasks cannot publish into the next selection.

The library's build owns dependency resolution, full graph validation, SDK recovery, source stability checks, compilation, and output verification. It checks the selected product against the package evaluated under the final recovered environment. Root and graph results are consumed within that build operation rather than loaded again. There is no persistent graph-validation cache.

The app retains compatible choices for automatic compiler recovery during Build. Exact selections and package pins remain fixed. If automatic recovery requires installation, the workflow retains its captured request and resumes only after approval. SDK candidates and compiler diagnostics stay inside the library.

Installed tools use shared read leases during inspection and builds, and exclusive leases for installation or removal. Package, scratch, and export mutations use ordered filesystem leases that also cover ancestors. This permits independent configuration while protecting overlapping storage and tool removal. The existing lock filename remains compatible with older SwiftlyKit processes.

The release catalog preserves its one-hour freshness budget across launches using the existing atomic cache file. Promotion from disk does not restart that budget. Expired metadata retains the existing installed-only outage fallback. Catalog requests have five-second request and resource timeouts. Installed compiler SDK probes run concurrently with structured cancellation and deterministic output order.

## Source observation must respect normal app resource limits

The final button-driven build found an existing resource problem after SDK recovery.
The normally launched app has the desktop's 256-descriptor soft limit. Creating
one FSEvents stream per dependency exhausted it; the system logged
`FSEventStreamCreate: ERROR: could not open kqueue`. The test host's larger limit
had hidden this failure.

FSEvents accepts multiple roots in one stream, but supports at most eight native
exclusions per stream. Exclusions apply across the stream. A nested source root
cannot be preserved by merely adding it beneath an excluded ancestor in the
same stream. [Apple stream creation API](https://developer.apple.com/documentation/coreservices/1443980-fseventstreamcreate?language=objc),
[installed Apple exclusion contract](/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk/System/Library/Frameworks/CoreServices.framework/Frameworks/FSEvents.framework/Headers/FSEvents.h:1420).

The implementation separates outer and nested roots into at most two streams.
Sibling checkouts share a watch anchor to avoid repeated ancestor watches.
Semantic source roots remain separate for snapshots and event filtering. Native
exclusions never contain another source root in the same stream. Remaining
exclusions stay in the callback filter. Root-change events and structural changes
to a watch ancestor invalidate the evidence, as required by
[Apple's root-change guidance](https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/UsingtheFSEventsFramework/UsingtheFSEventsFramework.html).

A new regression watches 120 checkouts and another dependency nested beneath a
checkout's `.build`. It accepts generated output and Git metadata, and detects a
source change followed by restoration. To test the actual resource constraint,
the isolated test process lowers its own soft limit after SwiftPM starts it:

```sh
SWIFTLYKIT_TEST_SOURCE_DESCRIPTOR_LIMIT=256 swift test --filter largeGraphObservation
```

Both cases passed with the asserted 256-descriptor limit. A separate regression
rejects moving and restoring the coalesced watch ancestor.

## Required evidence

- Measure package selection to usable configuration in the launched workspace app. Record its library revision and selected Swift version.
- Test Swift 6.4 with active SDK 27 and exact Swift 6.3.3 with the same active SDK.
- Put the scoped Foundation import in a dependency. Root configuration should succeed without graph work; build validation must recover to SDK 26.5 while retaining 6.3.3.
- Edit that dependency after a cached success. Build must expose the new error.
- Change compiler or SDK identity, traits, effective environment, or dependency resolution inputs. Reuse must not hide the change.
- Start an unrelated long build. Root configuration must not wait on its user-wide or scratch-directory lease.
- Cancel a selection, then select another package. No old completion may overwrite new state, and subprocess descendants must terminate.

## Verification on this Mac

The workspace overrides the app project's published SwiftlyKit dependency with
`/Users/berken/Development/Swift/SwiftlyKit`. The development launch script now
selects that workspace whenever the sibling library exists. The project lockfile
still selects public version 0.6.0. These changes require the local workspace until
a corresponding library release is published.

The displayed-window benchmark hosted the actual PackageSection and BuildSection,
including the keyed discovery task and the unchanged selection animation. It
measured selection until both configuration and the page transition completed.
Each selection used a fresh model. Official compilers, Linux SDKs, and the existing
disk caches were present; these are not empty-cache or installation timings.

| Selection | First selection | Second selection | Third selection |
| --- | ---: | ---: | ---: |
| Automatic, Swift 6.4.0, macOS SDK 27 | 1.995 s | 0.920 s | 1.051 s |
| Exact Swift 6.3.3, macOS SDK 27 | 1.513 s | 0.926 s | 0.918 s |

Every run passed the two-second limit. Evidence was recorded in
`/tmp/swiftlykit-configuration-benchmark-overlap.log` and
`/tmp/swiftlykit-configuration-timings.je2B3y`. Reproduce through
[benchmark_deployer_setup.sh](/Users/berken/Development/Swift/SwiftlyKitApp/script/benchmark_deployer_setup.sh).
The limit is a regression check on this setup, not a promise for installation,
an expired catalog refresh, or arbitrary package manifests.

The complete library suite passed 341 tests in 45 suites with the live host-cache
regression enabled. This reproduced dependency failure on SDK 27, recovery to
SDK 26.5 without changing Swift 6.3.3, successful cache reuse, and a visible new
error after editing the dependency manifest. It also covered filesystem aliases,
overlapping storage, cross-process exclusion, independent package work, and
cancellation of subprocess descendants.

The real Deployer app acceptance test passed with exact Swift 6.3.3. Its root
configuration succeeded on SDK 27. Build then recovered to SDK 26.5, compiled
and stripped a verified static x86-64 Linux executable. A root configuration
request made while that build owned its package leases completed independently.
Deployer's tracked files remained unchanged.

The separately launched development app also completed the same release build
through its actual Build button with exact Swift 6.3.3 and Strip Binary enabled.
Its UI reported success and the output was a stripped, statically linked x86-64
ELF executable. This exercised the desktop process limits that the test host
had missed.

The CLI's 15 tests in four suites passed against a temporary local-dependency
copy. The original CLI checkout remained unchanged. The app's focused staged
workflow checks passed 30 tests, including exact selection, approval and resume,
stale-result rejection, discovery before the transition, and both orders of
configuration and transition completion. Its 11 animation cases passed separately
without changing animation durations or pixel assertions. The initial combined
app run had two pixel equality failures; both unchanged cases passed when the
animation suite ran alone. Final app checks passed in three groups, 62 remaining
cases, 21 window-size cases, and 11 animation cases. Window suites ran separately
to avoid competing window captures. The opt-in real Deployer build and six-run
timing benchmark also passed.

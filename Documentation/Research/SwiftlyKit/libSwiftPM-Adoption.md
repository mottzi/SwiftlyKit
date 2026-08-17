# libSwiftPM Adoption in SwiftlyKit

**Reference date:** 17 August 2026

**Upstream baseline:** SwiftPM 6.3.3 at
[`5f6969f`](https://github.com/swiftlang/swift-package-manager/commit/5f6969f5b083b4415632114d4897c6f820761a7f),
SwiftPM `main` at
[`3e22779`](https://github.com/swiftlang/swift-package-manager/commit/3e2277952497247c2064745aefeef930fe199cff),
Swiftly `main` at
[`5ef4546`](https://github.com/swiftlang/swiftly/commit/5ef4546fecd36b803e3c313c830e10324466f0a1),
and SourceKit-LSP `main` at
[`7b387eb`](https://github.com/swiftlang/sourcekit-lsp/commit/7b387eb7bce9af20d92cc4c6520d55f18522960a)

**Status:** Recommendation against adoption

## Question

Should SwiftlyKit replace its `swift` command invocations with libSwiftPM, or
use libSwiftPM for selected operations while retaining subprocesses elsewhere?

## Recommendation

**No. SwiftlyKit should continue invoking the selected toolchain's SwiftPM
commands through `swift-subprocess`. It should not add either the full SwiftPM
library product or `SwiftPMDataModel` at this time.**

The process boundary is not incidental implementation glue. It gives
SwiftlyKit three properties that embedding libSwiftPM would weaken:

1. each operation uses the SwiftPM executable shipped with the caller-selected
   Swift toolchain;
2. each prepared workflow can receive its own environment and storage
   arguments without mutating host-process globals; and
3. SwiftlyKit depends on the CLI contract instead of an API that SwiftPM itself
   explicitly labels unstable.

Embedding libSwiftPM would also create an immediate distribution problem.
SwiftPM 6.3.3 is tagged `swift-6.3.3-RELEASE`, not with a modern semantic-version
tag, and its manifest pins several sibling repositories to the `release/6.3`
branch and several other packages to revisions. SwiftPM's own package API and
resolver enforce that a stable-version package cannot depend on an unstable
branch- or revision-based package. A released semantic version of SwiftlyKit
therefore cannot consume current SwiftPM as an ordinary source dependency
without a fork, vendoring, binary distribution, or forcing SwiftlyKit's users
onto branch/revision requirements.
[SwiftPM 6.3.3 dependency declarations](https://github.com/swiftlang/swift-package-manager/blob/5f6969f5b083b4415632114d4897c6f820761a7f/Package.swift#L1119-L1211),
[PackageDescription requirement rules](https://github.com/swiftlang/swift-package-manager/blob/5f6969f5b083b4415632114d4897c6f820761a7f/Sources/Runtimes/PackageDescription/PackageRequirement.swift#L13-L55),
[resolver enforcement](https://github.com/swiftlang/swift-package-manager/blob/5f6969f5b083b4415632114d4897c6f820761a7f/Sources/PackageGraph/Resolution/PubGrub/DiagnosticReportBuilder.swift#L211-L225),
[resolver test](https://github.com/swiftlang/swift-package-manager/blob/5f6969f5b083b4415632114d4897c6f820761a7f/Tests/PackageGraphTests/PubGrubTests.swift#L2454-L2487)

SwiftPM 6.3.3 also requires macOS 14 while SwiftlyKit supports macOS 13.
Adoption would make SwiftlyKit raise its deployment target. Current SwiftPM
`main` requires macOS 15, so following upstream would not restore that support.
[SwiftPM 6.3.3 platforms](https://github.com/swiftlang/swift-package-manager/blob/5f6969f5b083b4415632114d4897c6f820761a7f/Package.swift#L135-L157),
[SwiftPM `main` platforms](https://github.com/swiftlang/swift-package-manager/blob/3e2277952497247c2064745aefeef930fe199cff/Package.swift#L135-L157),
[SwiftlyKit platforms](https://github.com/mottzi/SwiftlyKit/blob/c797c8c744810b3a3339ca9e0aac34ef2a584371/Package.swift#L1-L20)

These are not temporary implementation inconveniences around an otherwise
better architecture. Even if distribution and deployment were solved,
embedding one SwiftPM version would conflict with SwiftlyKit's central purpose:
selecting different installed Swift toolchains and using each toolchain's own
compiler, PackageDescription runtime, plugins, SDK support, and SwiftPM
behavior.

## Decision summary

| Approach | Result | Assessment |
|---|---|---|
| Replace the CLI with libSwiftPM | SwiftlyKit constructs workspaces, resolves, and builds through SwiftPM modules | Reject. It couples every selected compiler to one embedded SwiftPM, loses normal package distribution, raises the deployment target, and requires substantial command-layer reconstruction. |
| Use libSwiftPM only for package inspection or graph loading | Inspection uses embedded SwiftPM; resolution and build use the selected toolchain's CLI | Reject for now. One workflow would use two SwiftPM versions and two environment models for little code reduction. |
| Dynamically load the selected toolchain's libSwiftPM | SwiftlyKit attempts to preserve version pairing without a source dependency | Reject. Toolchains do not promise a stable libSwiftPM installation, module ABI, or runtime API. |
| Keep the selected-toolchain CLI | SwiftlyKit invokes the selected toolchain's documented commands and interprets narrow outputs | **Choose.** This preserves version pairing, process isolation, deployment support, streaming, and cancellation while keeping SwiftlyKit small. |

## What SwiftlyKit relies on today

SwiftlyKit does not expose a generic shell wrapper. Its internal SwiftPM layer
uses a small, controlled command vocabulary:

- `swift package --disable-automatic-resolution … dump-package` to discover
  executable products;
- `swift package --disable-automatic-resolution … show-dependencies --format
  json` to obtain source roots without changing dependency state;
- `swift package … resolve` for explicit dependency resolution;
- `swift build --disable-automatic-resolution --swift-sdks-path … --swift-sdk
  … --product … --configuration …` for the cross-compiled product;
- the same build request with `--show-bin-path` to locate its output;
- `swift package … clean` or `reset` for SwiftPM-defined scratch cleanup; and
- `swift sdk list`, `install`, and `remove` for first-party SDK registry
  semantics.

The package-description, graph, resolution, build, and cleanup commands are
visible in SwiftlyKit's pinned 0.3.0 sources.
[package description](https://github.com/mottzi/SwiftlyKit/blob/c797c8c744810b3a3339ca9e0aac34ef2a584371/Sources/SwiftlyKit/SwiftPM/SwiftPM%2BPackageDescription.swift#L20-L58),
[package graph](https://github.com/mottzi/SwiftlyKit/blob/c797c8c744810b3a3339ca9e0aac34ef2a584371/Sources/SwiftlyKit/SwiftPM/SwiftPM%2BPackageGraph.swift#L3-L45),
[resolution](https://github.com/mottzi/SwiftlyKit/blob/c797c8c744810b3a3339ca9e0aac34ef2a584371/Sources/SwiftlyKit/SwiftPM/SwiftPM%2BResolution.swift#L3-L47),
[build and exact SDK selection](https://github.com/mottzi/SwiftlyKit/blob/c797c8c744810b3a3339ca9e0aac34ef2a584371/Sources/SwiftlyKit/SwiftPM/SwiftPM%2BBuild.swift#L5-L114),
[build arguments](https://github.com/mottzi/SwiftlyKit/blob/c797c8c744810b3a3339ca9e0aac34ef2a584371/Sources/SwiftlyKit/SwiftPM/SwiftPM%2BBuild.swift#L258-L289),
[cleanup](https://github.com/mottzi/SwiftlyKit/blob/c797c8c744810b3a3339ca9e0aac34ef2a584371/Sources/SwiftlyKit/SwiftPM/SwiftPM%2BCleanup.swift#L23-L78)

All selected-tool commands go through `swiftly run <tool> … +<version>`.
SwiftlyKit binds the prepared environment, shared SwiftPM paths, custom
environment namespace, package root, and sensitive-value markers at this one
command seam.
[SwiftlyKit selected-tool command](https://github.com/mottzi/SwiftlyKit/blob/c797c8c744810b3a3339ca9e0aac34ef2a584371/Sources/SwiftlyKit/Environment/Discovery/SwiftlyInstallation.swift#L91-L133),
[SwiftPM command binding](https://github.com/mottzi/SwiftlyKit/blob/c797c8c744810b3a3339ca9e0aac34ef2a584371/Sources/SwiftlyKit/SwiftPM/SwiftPM%2BCommand.swift#L22-L100)

Swiftly implements that selection by constructing the chosen toolchain's proxy
environment and preferring the chosen toolchain's `usr/bin` executable over
system tools. Consequently, `swift build` is the SwiftPM paired with that
installed toolchain, rather than whichever SwiftPM SwiftlyKit happened to be
compiled against.
[Swiftly run contract](https://github.com/swiftlang/swiftly/blob/5ef4546fecd36b803e3c313c830e10324466f0a1/Sources/Swiftly/Run.swift#L7-L39),
[Swiftly executable selection](https://github.com/swiftlang/swiftly/blob/5ef4546fecd36b803e3c313c830e10324466f0a1/Sources/Swiftly/Run.swift#L99-L125)

After SwiftPM finishes, SwiftlyKit still supplies its own domain guarantees:
product validation, dependency-resolution policy, exact SDK visibility, source
stability checks, executable and resource discovery, ELF architecture
verification, stripping, atomic publication, and cleanup or environment-removal
semantics. Those guarantees do not disappear when SwiftPM is embedded. The
replaceable part is only the outer command construction and process boundary.

The CLI boundary is not risk-free. Command flags, JSON payloads, human
diagnostics, and line-oriented SDK output can change between Swift releases;
process launch also has a small fixed cost. SwiftlyKit should continue
mitigating those risks by keeping the command vocabulary private and narrow,
decoding only the fields it needs, bounding diagnostics, and exercising the
supported toolchain generations in fixtures. Those costs are smaller and more
observable than compiling against unstable source APIs, and the launch cost is
negligible beside manifest evaluation, dependency resolution, and a real
cross-compilation build.

## libSwiftPM is available, but not a stable library contract

SwiftPM publishes two source products. `SwiftPMDataModel` includes package
collections, package loading, the package graph, source control, and `Workspace`.
The full `SwiftPM` product adds the build and llbuild-related targets. The
manifest describes the latter as all SwiftPM code except the command-line tools
and immediately states: **“This API is unstable and may change at any time.”**
[SwiftPM library products and stability notice](https://github.com/swiftlang/swift-package-manager/blob/5f6969f5b083b4415632114d4897c6f820761a7f/Package.swift#L51-L100)

That warning corresponds to observable source churn. For example, between
SwiftPM 6.2.4 and 6.3.3, `BuildOperation.build` changed from an async throwing
method with no result to a method with another argument and a `BuildResult`
return value.
[SwiftPM 6.2.4 build interface](https://github.com/swiftlang/swift-package-manager/blob/215e9f91823d7e44c379fa17bf1eef189438fc24/Sources/Build/BuildOperation.swift#L393-L430),
[SwiftPM 6.3.3 build interface](https://github.com/swiftlang/swift-package-manager/blob/5f6969f5b083b4415632114d4897c6f820761a7f/Sources/Build/BuildOperation.swift#L398-L430)

Open source therefore answers whether SwiftlyKit can inspect and compile the
code. It does not establish semantic-version compatibility, API stability,
library evolution, or support for independently released external libraries.

### The useful command layer is excluded

The library products do not include `CoreCommands`, `Commands`, or
`SwiftSDKCommand`. Those targets contain the high-level command state and the
SDK subcommands. The executable targets depend on them separately.
[command targets](https://github.com/swiftlang/swift-package-manager/blob/5f6969f5b083b4415632114d4897c6f820761a7f/Package.swift#L577-L638),
[executable targets](https://github.com/swiftlang/swift-package-manager/blob/5f6969f5b083b4415632114d4897c6f820761a7f/Package.swift#L693-L725)

This distinction is important. Adding `SwiftPM-auto` would make lower-level
types importable, but it would not provide a supported equivalent of “perform
this `swift build` with these global options.” SwiftlyKit would have to rebuild
the orchestration that the executable target already owns.

`SwiftCommandState` illustrates the hidden depth. It derives scratch, shared
configuration, security, cache, and SDK paths; acquires workspace locks;
constructs authorization, registry, fingerprint, signing, resolver, trait,
manifest, and delegate configuration; creates plugin runners and registers
them for cancellation; derives separate host and target toolchains; selects the
target Swift SDK; and configures sandboxed manifest loading.
[location and trait setup](https://github.com/swiftlang/swift-package-manager/blob/5f6969f5b083b4415632114d4897c6f820761a7f/Sources/CoreCommands/SwiftCommandState.swift#L390-L424),
[workspace construction](https://github.com/swiftlang/swift-package-manager/blob/5f6969f5b083b4415632114d4897c6f820761a7f/Sources/CoreCommands/SwiftCommandState.swift#L485-L552),
[plugin runner](https://github.com/swiftlang/swift-package-manager/blob/5f6969f5b083b4415632114d4897c6f820761a7f/Sources/CoreCommands/SwiftCommandState.swift#L801-L815),
[target and host toolchains](https://github.com/swiftlang/swift-package-manager/blob/5f6969f5b083b4415632114d4897c6f820761a7f/Sources/CoreCommands/SwiftCommandState.swift#L1013-L1082),
[manifest loader](https://github.com/swiftlang/swift-package-manager/blob/5f6969f5b083b4415632114d4897c6f820761a7f/Sources/CoreCommands/SwiftCommandState.swift#L1084-L1113)

Copying that setup would increase SwiftlyKit's implementation and test burden
while making it responsible for tracking an explicitly unstable internal
design. Importing `CoreCommands` directly is not a solution: it is not in the
library product, uses package-scoped and command-parser APIs, and would bind
SwiftlyKit even more tightly to the executable implementation.

## Distribution and platform blockers

### SwiftPM is not packaged for a tagged library dependency

The upstream repository has a `swift-6.3.3-RELEASE` tag, but no corresponding
modern SemVer tag such as `6.3.3`. Its SemVer-looking release tags stop at the
old `0.6.0` line; modern toolchain releases use Swift project tag names.
[SwiftPM tags](https://github.com/swiftlang/swift-package-manager/tags),
[SwiftPM 6.3.3 release-tag tree](https://github.com/swiftlang/swift-package-manager/tree/swift-6.3.3-RELEASE),
[historical 0.6.0 tree](https://github.com/swiftlang/swift-package-manager/tree/0.6.0)

Depending on the 6.3.3 commit instead does not solve publication. Its manifest
uses `release/6.3` branches for `swift-llbuild`, `swift-syntax`,
`swift-tools-support-core`, `swift-driver`, and `swift-build`, plus revision
requirements for argument parser, crypto, system, collections, certificates,
SQLite, and tools protocols. The manifest explains that several of these must
match the versions used to build the official Swift toolchain.
[SwiftPM 6.3.3 dependency graph](https://github.com/swiftlang/swift-package-manager/blob/5f6969f5b083b4415632114d4897c6f820761a7f/Package.swift#L1128-L1211)

SwiftPM's published dependency rules say branch and commit requirements are
for packages developed in tandem or exceptional cases, and that they must be
removed before a version is published. Its resolver diagnoses a stable package
that depends on an unstable package, and its tests require resolution to fail
for that graph.
[branch and commit requirement documentation](https://github.com/swiftlang/swift-package-manager/blob/5f6969f5b083b4415632114d4897c6f820761a7f/Sources/Runtimes/PackageDescription/PackageRequirement.swift#L30-L55),
[stable-to-unstable diagnostic](https://github.com/swiftlang/swift-package-manager/blob/5f6969f5b083b4415632114d4897c6f820761a7f/Sources/PackageGraph/Resolution/PubGrub/DiagnosticReportBuilder.swift#L211-L225),
[enforcement test](https://github.com/swiftlang/swift-package-manager/blob/5f6969f5b083b4415632114d4897c6f820761a7f/Tests/PackageGraphTests/PubGrubTests.swift#L2454-L2487)

This is a hard downstream-distribution constraint, not merely a preference for
clean manifests. A tagged SwiftlyKit release with that source graph could not
be consumed by another package through a normal version requirement.

The possible workarounds are all disproportionate:

- **Fork or vendor SwiftPM:** SwiftlyKit would own a large, frequently changing
  dependency graph and reconcile it with every supported Swift generation.
- **Ship a binary SwiftPM library:** upstream does not promise library
  evolution or a stable ABI for these products. SwiftlyKit would become a
  binary distributor across host architectures, compiler versions, and minimum
  operating systems.
- **Require branch/revision use of SwiftlyKit:** ordinary tagged consumption
  would be lost, shifting SwiftPM's packaging limitation onto every consumer.
- **Use an old SemVer tag:** `0.6.0` predates modern Swift SDKs, traits, and the
  current toolchain behavior SwiftlyKit needs.

### The deployment-target cost is real

SwiftlyKit 0.3.0 supports macOS 13. SwiftPM 6.3.3 declares macOS 14, and current
`main` declares macOS 15. SwiftPM is free to choose deployment targets for its
toolchain-coordinated clients; SwiftlyKit should not make those targets part of
its public compatibility floor merely to replace process calls that already
work on macOS 13.

## Toolchain and manifest compatibility

### Selecting a compiler is not the same as selecting SwiftPM

libSwiftPM's `UserToolchain` can be pointed at custom search paths and a Swift
compiler. It then locates the selected compiler and attempts to derive the
matching PackageDescription and plugin library locations from the toolchain.
The derivation is explicitly described in source as fragile.
[custom toolchain search](https://github.com/swiftlang/swift-package-manager/blob/5f6969f5b083b4415632114d4897c6f820761a7f/Sources/PackageModel/UserToolchain.swift#L714-L795),
[SwiftPM runtime-library derivation](https://github.com/swiftlang/swift-package-manager/blob/5f6969f5b083b4415632114d4897c6f820761a7f/Sources/PackageModel/UserToolchain.swift#L915-L1012)

That supports using an external compiler from one embedded SwiftPM. It does not
turn the embedded SwiftPM 6.3.3 algorithms and model types into SwiftPM 6.0,
6.1, 6.2, or a future 6.4. SwiftPM compiles its own current package-manager
version into `SwiftVersion.current`; `ToolsVersion.current` is derived from
that value.
[compiled package-manager version](https://github.com/swiftlang/swift-package-manager/blob/5f6969f5b083b4415632114d4897c6f820761a7f/Sources/Basics/SwiftVersion.swift#L52-L65),
[current tools version](https://github.com/swiftlang/swift-package-manager/blob/5f6969f5b083b4415632114d4897c6f820761a7f/Sources/PackageModel/ToolsVersion.swift#L37-L47)

The current subprocess design instead selects the complete installed toolchain
front end. This naturally pairs the compiler with the SwiftPM release that
knows its tools-version rules, manifest schema, feature set, build parameters,
plugin protocol, and SDK behavior. With libSwiftPM, SwiftlyKit would need a
compatibility matrix for every combination of embedded SwiftPM and selected
toolchain, including combinations upstream does not promise to support.

### Manifest loading still executes untrusted package code

Embedding does not turn `Package.swift` into passive data. SwiftPM's
`ManifestLoader` compiles the manifest with a Swift compiler against the
toolchain's PackageDescription runtime, executes the compiled program, and
decodes its JSON result. SwiftPM reports serialization errors when the
PackageDescription runtime and loader disagree.
[manifest-loader purpose and serialization errors](https://github.com/swiftlang/swift-package-manager/blob/5f6969f5b083b4415632114d4897c6f820761a7f/Sources/PackageLoading/ManifestLoader.swift#L70-L94),
[manifest evaluation design](https://github.com/swiftlang/swift-package-manager/blob/5f6969f5b083b4415632114d4897c6f820761a7f/Sources/PackageLoading/ManifestLoader.swift#L253-L259),
[runtime selection and compilation](https://github.com/swiftlang/swift-package-manager/blob/5f6969f5b083b4415632114d4897c6f820761a7f/Sources/PackageLoading/ManifestLoader.swift#L705-L808)

The loader applies SwiftPM's manifest sandbox before execution, so a correct
embedded implementation would need to preserve that setup rather than treating
package inspection as a harmless in-process parse.
[manifest sandbox and execution](https://github.com/swiftlang/swift-package-manager/blob/5f6969f5b083b4415632114d4897c6f820761a7f/Sources/PackageLoading/ManifestLoader.swift#L876-L908)

The CLI already provides the selected release's compatible manifest compiler,
runtime, sandbox policy, and decoder as one unit.

## Environment, storage, and statelessness

SwiftlyKit snapshots a `SwiftPMEnvironment` during preparation and passes that
snapshot to every relevant child process. Independent tasks can therefore run
with different environment overlays, cache/configuration/security roots,
scratch roots, and environment namespaces without changing the embedding
application's process-wide state.

SwiftPM's lower-level types accept environment values in several important
places, including `UserToolchain`, but the abstraction is not uniformly
instance-scoped. In SwiftPM 6.3.3, `ManifestLoader` builds the environment for
the compiled manifest from `Environment.current`. Its cache key also includes
the current host environment.
[manifest cache environment](https://github.com/swiftlang/swift-package-manager/blob/5f6969f5b083b4415632114d4897c6f820761a7f/Sources/PackageLoading/ManifestLoader.swift#L472-L486),
[manifest execution environment](https://github.com/swiftlang/swift-package-manager/blob/5f6969f5b083b4415632114d4897c6f820761a7f/Sources/PackageLoading/ManifestLoader.swift#L889-L908)

To reproduce SwiftlyKit's current semantics with libSwiftPM, SwiftlyKit would
have to choose among three poor options:

- mutate the application process environment around an asynchronous operation,
  which is race-prone when workflows overlap;
- accept that manifest conditions and subprocesses no longer see the requested
  environment consistently; or
- fork or wrap SwiftPM internals to thread an explicit environment through
  every relevant path.

The child-process boundary avoids the problem. Each command receives its own
complete environment and SwiftPM remains responsible for forwarding it to its
own manifest, plugin, compiler, Git, and build subprocesses.

The same principle applies to storage. SwiftlyKit currently expresses
caller-owned scratch, cache, configuration, security, environment, and SDK
locations through command arguments and the child environment. Embedding would
require SwiftlyKit to reconstruct `Workspace.Location` and preserve SwiftPM's
locking and ownership rules. This would not deepen SwiftlyKit's public module;
it would duplicate private orchestration beneath the same public API.

## Static Linux SDK lifecycle

SwiftPM does expose a public `SwiftSDKBundleStore` with selection and
installation methods. That makes SDK installation look like a plausible narrow
adoption candidate.
[Swift SDK bundle store](https://github.com/swiftlang/swift-package-manager/blob/5f6969f5b083b4415632114d4897c6f820761a7f/Sources/PackageModel/SwiftSDKs/SwiftSDKBundleStore.swift#L21-L163)

It is not a complete standalone SDK-manager contract. Construction requires
SwiftPM filesystem, observability, archive, HTTP, hashing, and toolchain
concepts. Removal is implemented by a package-scoped `RemoveSwiftSDK` command
inside `SwiftSDKCommand`, a target excluded from the library products. It also
contains bundle-versus-artifact disambiguation and interactive safety behavior
that SwiftlyKit would have to reproduce.
[Swift SDK removal implementation](https://github.com/swiftlang/swift-package-manager/blob/5f6969f5b083b4415632114d4897c6f820761a7f/Sources/SwiftSDKCommand/RemoveSwiftSDK.swift#L19-L114)

Using the store for installation while retaining `swift sdk list/remove` would
split one lifecycle across two SwiftPM versions and two implementations. It
would not reduce SwiftlyKit's dependency on subprocesses because Swiftly,
toolchain installation, removal, and `llvm-objcopy` still require them. The
selected toolchain's `swift sdk` command remains the smaller and more coherent
boundary.

## Resolution, inspection, and build by operation

### Package inspection

`ManifestLoader` or `Workspace` could replace `dump-package`. Doing so would
replace a narrow JSON decoder with manifest compiler/runtime setup, sandboxing,
observability, cache configuration, and cross-version compatibility. It would
also use the embedded SwiftPM for inspection while the selected toolchain's
SwiftPM performs the build. The two could disagree on supported tools versions,
traits, products, or manifest schema.

**Assessment:** technically possible, architecturally worse.

### Dependency graph inspection

`Workspace` can load a package graph, but SwiftlyKit specifically requests a
read-only graph with automatic resolution disabled so it can detect missing
resolution before building. A correct replacement must recreate workspace
locations, mirrors, registries, credentials, fingerprints, signing policy,
traits, manifest loading, locking, and delegate behavior. The command layer
already composes those details.

**Assessment:** possible, but increases implementation and behavioral risk.

### Dependency resolution

`Workspace` exposes high-level resolution and graph-loading operations. Those
operations are only one part of the CLI behavior. SwiftlyKit would still need
the command state's authorization providers, registry configuration,
fingerprint and signing stores, dependency cache, resolver configuration,
workspace lock, observability, cancellation, and diagnostic mapping.

**Assessment:** no meaningful code-size or complexity reduction.

### Cross-compilation build

The full library product includes `BuildOperation`, but not the `swift build`
command setup. SwiftlyKit would need to construct host and target toolchains,
derive and select the Static Linux SDK, construct build parameters for products
and tools, load the graph, configure plugins, choose and operate a build system,
integrate cancellation, and locate outputs. It would still perform its own
source-stability, filesystem, ELF, resource, publication, and cleanup checks.

**Assessment:** this is a replacement of SwiftPM's command front end, not a
simplification of SwiftlyKit.

### Cleanup

SwiftlyKit could delete scratch paths itself or call lower-level workspace
operations, but its current API intentionally asks SwiftPM to apply `clean` and
`reset` semantics. Retaining the CLI lets those semantics evolve with the
selected toolchain and avoids broadening SwiftlyKit's filesystem ownership.

**Assessment:** retain the CLI.

## Output, cancellation, and security

SwiftlyKit's one subprocess adapter streams standard output and standard error,
redacts caller-marked sensitive values before retaining or forwarding output,
bounds retained diagnostics, checks Swift task cancellation, starts a separate
process session, and uses graceful process-group teardown.
[SwiftlyKit subprocess execution](https://github.com/mottzi/SwiftlyKit/blob/c797c8c744810b3a3339ca9e0aac34ef2a584371/Sources/SwiftlyKit/Subprocess/LiveSubprocessRunner.swift#L5-L55),
[streaming and bounded retention](https://github.com/mottzi/SwiftlyKit/blob/c797c8c744810b3a3339ca9e0aac34ef2a584371/Sources/SwiftlyKit/Subprocess/LiveSubprocessRunner.swift#L72-L115),
[process-group teardown](https://github.com/mottzi/SwiftlyKit/blob/c797c8c744810b3a3339ca9e0aac34ef2a584371/Sources/SwiftlyKit/Subprocess/LiveSubprocessRunner.swift#L117-L129)

libSwiftPM offers observability and build-system delegates, but those are not a
drop-in equivalent of the current merged command-output contract. SwiftPM also
has a `Cancellator`, yet the embedding host must create it, register relevant
processes and plugin runners, and bridge Swift task cancellation to its
deadline-based cancellation method.
[SwiftPM cancellation registry](https://github.com/swiftlang/swift-package-manager/blob/5f6969f5b083b4415632114d4897c6f820761a7f/Sources/Basics/Cancellator.swift#L100-L141),
[cancellation cycle](https://github.com/swiftlang/swift-package-manager/blob/5f6969f5b083b4415632114d4897c6f820761a7f/Sources/Basics/Cancellator.swift#L141-L190),
[build-system delegate](https://github.com/swiftlang/swift-package-manager/blob/5f6969f5b083b4415632114d4897c6f820761a7f/Sources/SPMBuildCore/BuildSystem/BuildSystemDelegate.swift#L16-L45)

Embedding would not eliminate process management. SwiftPM still launches
manifest compilers and executables, build plugins, compiler and linker jobs,
Git, and build-system processes. It would remove only the outer `swift`
process, while making SwiftlyKit responsible for coordinating the inner ones.
For real cross-compilation builds, saving that one startup is not a meaningful
performance benefit.

The subprocess boundary also limits failure and global-state contamination from
an unstable build engine. It is not a security sandbox by itself, but it allows
the selected SwiftPM executable to apply its own manifest and plugin sandbox
policies and gives SwiftlyKit one process group to cancel. An embedded design
must reproduce those policies correctly for every supported SwiftPM version.

## Dependency, build, and maintenance cost

SwiftlyKit currently has one exact dependency, `swift-subprocess` 1.0.0. The
full SwiftPM product contains twelve broad targets spanning package
collections, source control, workspace, build planning, llbuild, and
SourceKit-LSP integration. Even `SwiftPMDataModel` includes eight targets and a
full workspace.
[SwiftlyKit manifest](https://github.com/mottzi/SwiftlyKit/blob/c797c8c744810b3a3339ca9e0aac34ef2a584371/Package.swift#L1-L28),
[SwiftPM product composition](https://github.com/swiftlang/swift-package-manager/blob/5f6969f5b083b4415632114d4897c6f820761a7f/Package.swift#L51-L100)

SwiftPM's 6.3.3 source manifest declares thirteen first-order package
dependencies across branch, revision, and version requirements. Exact compiled
and linked size depends on the selected product and build configuration, so
this review does not claim a fixed binary-size number. The structural cost is
nevertheless clear: adopting SwiftPM replaces one small stable dependency with
a toolchain-scale source graph and longer consumer resolution/builds.

Maintenance would move from testing a narrow documented command surface to:

- adapting to unstable source changes in SwiftPM and its sibling projects;
- validating embedded-SwiftPM × selected-toolchain combinations;
- maintaining manifest, plugin, resolver, registry, SDK, and build-system setup;
- recreating streaming, cancellation, sandbox, and diagnostic behavior; and
- packaging or forking upstream so tagged SwiftlyKit releases remain usable.

That cost is contrary to SwiftlyKit's focused, lightweight, and largely
stateless scope.

## Why SourceKit-LSP does not change the conclusion

SwiftPM identifies SourceKit-LSP as a libSwiftPM user. That is evidence that
the library is useful, not that it is a stable package dependency for every
kind of client.
[SwiftPM README](https://github.com/swiftlang/swift-package-manager/blob/5f6969f5b083b4415632114d4897c6f820761a7f/README.md#L5-L10)

SourceKit-LSP is developed as part of the Swift toolchain family. In CI it uses
sibling local checkouts controlled by the external toolchain build. Outside
that mode, its current manifest follows `main` branches for SwiftPM and related
projects rather than consuming stable versions.
[SourceKit-LSP dependency strategy](https://github.com/swiftlang/sourcekit-lsp/blob/7b387eb7bce9af20d92cc4c6520d55f18522960a/Package.swift#L774-L834)

That is an appropriate trade for an IDE service co-developed with SwiftPM and
the toolchain. It is not the distribution or compatibility model of a small
semantic-versioned library intended to drive caller-selected installed
toolchains.

## Why a dynamically loaded toolchain library is not viable

SwiftPM's bootstrap script installs libSwiftPM only when an explicit
`libswiftpm_install_dir` is supplied. A normal toolchain installation therefore
cannot be assumed to contain a loadable libSwiftPM in a stable location.
[optional libSwiftPM installation](https://github.com/swiftlang/swift-package-manager/blob/5f6969f5b083b4415632114d4897c6f820761a7f/Utilities/bootstrap#L500-L539)

Even if every Swiftly toolchain happened to ship a dynamic library, SwiftlyKit
would still need a compile-time module interface and a runtime ABI compatible
with every selected release. SwiftPM promises neither. `dlopen`, ad hoc search
paths, or per-release shims would turn SwiftlyKit into a compatibility and
binary-loading framework. Invoking the selected executable is the supported
cross-version boundary already present in each toolchain.

## Is any narrow libSwiftPM use worthwhile?

**Not with the current upstream products.**

`SwiftPMDataModel` is smaller than the full build product, but still includes
package loading, source control, graph, and workspace machinery, carries the
same explicit instability and distribution constraints, and creates the same
embedded-versus-selected version split. Adding it only to decode a package or
graph would make the dependency surface much larger than SwiftlyKit's existing
narrow JSON models.

SwiftlyKit should reconsider a narrow adoption only if upstream provides an
official product with all of these properties:

1. modern SemVer releases whose transitive graph is valid for versioned
   downstream packages;
2. a documented external-consumer compatibility policy;
3. a deployment target compatible with SwiftlyKit;
4. an explicit per-instance environment and storage contract;
5. a supported way to bind behavior to an external selected toolchain; and
6. enough end-to-end operation surface to replace, rather than duplicate, the
   CLI command layer.

A stable, small package-metadata decoder might someday meet those conditions.
It could then replace SwiftlyKit's `dump-package` JSON decoding without
bringing in resolution or build machinery. No current libSwiftPM product does.

## Resulting architecture

SwiftlyKit should keep the existing ownership boundary:

```text
SwiftlyKit
├── owns cross-compilation policy and verification
├── snapshots caller environment and storage choices
├── selects an installed Swift toolchain through Swiftly
├── invokes that toolchain's SwiftPM CLI through one subprocess adapter
└── converts narrow command results into SwiftlyKit domain values

Selected Swift toolchain
├── owns its matching SwiftPM implementation
├── interprets Package.swift and tools-version semantics
├── resolves dependencies and applies registry/security policy
├── selects and interprets the Static Linux SDK
└── plans and executes the build
```

This boundary is deeper than embedding lower-level SwiftPM types: a small
SwiftlyKit interface hides the toolchain/version selection, arguments,
environment, storage, output, cancellation, safety checks, and artifact
verification while leaving SwiftPM internals with the release that owns them.

## Final assessment

libSwiftPM is valuable for tightly coupled Swift-toolchain clients that accept
source instability and coordinated branch builds. SwiftlyKit is not such a
client. Its value comes from mediating among independently installed Swift
toolchains through a stable, narrow library API.

Migrating would make SwiftlyKit larger, less distributable, less portable,
less stateless under concurrent embedding, and more tightly coupled to one
SwiftPM release. It would not eliminate subprocesses or replace SwiftlyKit's
verification and publication logic. A selective hybrid would add most of the
cost while making a single workflow depend on two SwiftPM versions.

**Keep the subprocess implementation. There is no current libSwiftPM feature
whose adoption would make SwiftlyKit simpler or more correct.**

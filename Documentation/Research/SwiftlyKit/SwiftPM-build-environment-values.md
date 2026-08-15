# SwiftPM Build Environment Values in SwiftlyKit

**Reference date:** 15 August 2026

**Upstream baseline:** SwiftPM `main` at
[`17c2e6a`](https://github.com/swiftlang/swift-package-manager/commit/17c2e6a797ec5a067f52c2bee2f386f3ba2ba277),
plus accepted SE-0450 and current official SwiftPM documentation

**Status:** Adopted as a workflow-scoped SwiftlyKit feature

## Question

Is a caller-supplied environment overlay useless for SwiftlyKit, even if it
were implemented consistently across the complete SwiftPM workflow?

## Finding

**No. “Useless” is too strong.** SwiftPM has real, first-party environment use
cases that can matter to a cross-compilation orchestrator:

- noninteractive credentials for registry packages, binary artifacts, and
  prebuilts;
- `pkg-config` discovery and sysroot adjustment for system-library targets;
- environment-sensitive manifests, including an official public
  `Context.environment` API;
- host-tool and compiler discovery overrides; and
- plugin logic and build-time code generation.

However, these are not one coherent “extra environment values for this build”
feature. They have different lifetimes, trust boundaries, propagation rules,
and safer first-class alternatives. A complete arbitrary `[String: String]`
overlay would be useful as an escape hatch, but it would also substantially
broaden SwiftlyKit's contract.

SwiftlyKit supports the concrete professional workflows identified here without
making environment data a build-request option. `SwiftPMEnvironment` binds one
validated snapshot during preparation. That snapshot applies to the complete
SwiftPM workflow and protects the prepared toolchain and SDK invariants.

The current `BuildRequest.environment` shape is especially problematic because
its documented propagation to build, bin-path, and strip is neither the phase
set required by SwiftPM nor a meaningful security boundary.

## Legitimate use cases

### 1. Dependency and binary-artifact authentication

SwiftPM explicitly documents environment credentials for CI, where Keychain
and `.netrc` can be impractical:

- `SWIFTPM_REGISTRY_TOKEN`, or the paired
  `SWIFTPM_REGISTRY_LOGIN` / `SWIFTPM_REGISTRY_PASSWORD`, authenticates package
  registry requests;
- `SWIFTPM_SOURCE_CONTROL_TOKEN` authenticates HTTP downloads of binary targets
  and prebuilts, but not `git clone` or `git fetch`; and
- `SWIFTPM_NETRC_DATA` carries per-host netrc data.

SwiftPM says these environment credentials take precedence over persisted
credentials and shows `export ...; swift build` as the intended CI workflow.
[SwiftPM package-registry authentication documentation](https://github.com/swiftlang/swift-package-manager/blob/17c2e6a797ec5a067f52c2bee2f386f3ba2ba277/Documentation/PackageRegistry/PackageRegistryUsage.md#L130-L194)

The implementation reads those variables when constructing authorization
providers for source-control/binary downloads and registry operations.
[SwiftPM authorization configuration](https://github.com/swiftlang/swift-package-manager/blob/17c2e6a797ec5a067f52c2bee2f386f3ba2ba277/Sources/Workspace/Workspace%2BConfiguration.swift#L306-L390)

This is a genuine reason for an embedding library to care about environment
values. It is not naturally a `BuildRequest` concern, though: credentials are
needed when SwiftlyKit explicitly resolves or downloads dependencies. Passing
them only to a later `swift build --disable-automatic-resolution` invocation is
too late.

SwiftPM also provides safer persistent alternatives: registry login stores
credentials in the operating-system credential store or `.netrc`, and normal
source-control Git operations use Git's own credential helpers or SSH keys.
[SwiftPM registry credential storage](https://github.com/swiftlang/swift-package-manager/blob/17c2e6a797ec5a067f52c2bee2f386f3ba2ba277/Documentation/PackageRegistry/PackageRegistryUsage.md#L104-L129)

### 2. Cross-compilation system-library discovery

SwiftPM's `PkgConfig` loader searches `PKG_CONFIG_PATH` and applies
`PKG_CONFIG_SYSROOT_DIR`. These can be necessary when a cross-compiled package
contains a `systemLibrary` target whose `.pc` files or paths do not belong to
the host system.
[SwiftPM `PkgConfig` environment handling](https://github.com/swiftlang/swift-package-manager/blob/17c2e6a797ec5a067f52c2bee2f386f3ba2ba277/Sources/PackageLoading/PkgConfig.swift#L35-L40),
[sysroot and path implementation](https://github.com/swiftlang/swift-package-manager/blob/17c2e6a797ec5a067f52c2bee2f386f3ba2ba277/Sources/PackageLoading/PkgConfig.swift#L84-L93)

This is the environment use case most directly connected to SwiftlyKit's
cross-compilation purpose. Even here, SwiftPM has a first-class
`--pkg-config-path` option, introduced specifically as an alternative to
`PKG_CONFIG_PATH`, and it supports explicit `-Xcc` and `-Xlinker` search paths.
[SwiftPM 5.8 release note](https://docs.swift.org/swiftpm/documentation/packagemanagerdocs/5.8),
[system-library guide](https://docs.swift.org/swiftpm/documentation/packagemanagerdocs/addingsystemlibrarydependency/)

Swift SDK and toolset configuration are also more precise places for stable
target SDK, compiler, include, and library paths than a request-local process
environment. The current `swift build` interface exposes `--swift-sdk`,
`--toolset`, `--pkg-config-path`, `-Xcc`, `-Xswiftc`, and `-Xlinker` directly.
[Official `swift build` interface](https://docs.swift.org/swiftpm/documentation/packagemanagerdocs/swiftbuild/)

### 3. Manifest-controlled package shape

`PackageDescription.Context.environment` is public API and returns a snapshot
of the system environment to `Package.swift`.
[PackageDescription `Context.environment`](https://github.com/swiftlang/swift-package-manager/blob/17c2e6a797ec5a067f52c2bee2f386f3ba2ba277/Sources/Runtimes/PackageDescription/Context.swift#L13-L41)

This is used in practice by first-party Swift packages. For example,
`swift-testing` uses environment values to choose local dependencies and to
approximate whether it is being built for Embedded Swift, while explicitly
calling the latter inference experimental.
[swift-testing manifest](https://github.com/swiftlang/swift-testing/blob/849a60454b14da159a11dacc1760b18b03188b45/Package.swift#L16-L41)

That proves the mechanism can affect dependencies, platforms, products,
targets, settings, and resources observed by an orchestrator. It does **not**
make arbitrary manifest configuration a sound SwiftlyKit feature. Accepted
SE-0450 says packages have used manifest environment values for optional
dependencies and development defines, but also says that doing so is not
officially supported and may break under stricter sandboxing. Package traits
were introduced as the explicit replacement for those configuration needs.
[SE-0450 motivation and proposed replacement](https://github.com/swiftlang/swift-evolution/blob/4cdd9ffdc9f312378d230250b5e8f83aa7e2e361/proposals/0450-swiftpm-package-traits.md#L35-L66)

Traits are discoverable, modelled in the package graph, additive, and selectable
with `swift build --traits`, `--enable-all-traits`, and
`--disable-default-traits`. They are a much better future SwiftlyKit option than
supporting environment-controlled manifest variants as a product feature.
[SwiftPM traits guide](https://docs.swift.org/swiftpm/documentation/packagemanagerdocs/packagetraits/)

### 4. Toolchain and compiler process configuration

The process environment is not just data available to package code. SwiftPM
uses it to find tools. Current source consults `PATH`, `SWIFT_EXEC`,
`SWIFT_EXEC_MANIFEST`, `CC`, `AR`/`LIBTOOL`, and `SDKROOT`, among other values.
For example, `SWIFT_EXEC` can replace the compiler and `CC` can replace Clang.
[SwiftPM compiler selection](https://github.com/swiftlang/swift-package-manager/blob/17c2e6a797ec5a067f52c2bee2f386f3ba2ba277/Sources/PackageModel/UserToolchain.swift#L367-L441),
[Clang selection](https://github.com/swiftlang/swift-package-manager/blob/17c2e6a797ec5a067f52c2bee2f386f3ba2ba277/Sources/PackageModel/UserToolchain.swift#L444-L469)

Those overrides are useful for SwiftPM development and unusual toolchains, but
they conflict with SwiftlyKit's stronger promise to bind a build to one prepared
Swiftly toolchain and one exact Static Linux SDK. A public arbitrary overlay
would either need a documented denylist of invariant-breaking keys or accept
that callers can defeat the prepared environment.

### 5. Plugins and generated build tools

SwiftPM runs a plugin script as a separate process with the current process
environment, so plugin code can observe values through Foundation.
[Plugin process environment](https://github.com/swiftlang/swift-package-manager/blob/17c2e6a797ec5a067f52c2bee2f386f3ba2ba277/Sources/SPMBuildCore/Plugins/DefaultPluginScriptRunner.swift#L460-L499)

The tool that a build plugin asks SwiftPM to run is a different boundary. The
plugin's `Command` explicitly declares the environment assignments visible to
that executable; its default is empty.
[PackagePlugin `Command.environment`](https://github.com/swiftlang/swift-package-manager/blob/17c2e6a797ec5a067f52c2bee2f386f3ba2ba277/Sources/Runtimes/PackagePlugin/Command.swift#L22-L87)

Moreover, the official SwiftPM 6.3 Swift Build migration notes say Swift Build
does not pass environment variables to plugin tools, and SwiftPM 6.4 makes
Swift Build the default. That makes implicit outer-environment delivery to a
generator an unsuitable portable contract for SwiftlyKit.
[Swift Build plugin-tool limitation](https://docs.swift.org/swiftpm/documentation/packagemanagerdocs/swiftbuildpreview/),
[SwiftPM 6.4 default-build-system note](https://docs.swift.org/swiftpm/documentation/packagemanagerdocs/6.4/)

If a generator needs configuration, the package/plugin should model it through
declared command arguments, explicit command environment, configuration files,
and declared input files. SwiftlyKit cannot reliably turn an arbitrary outer
environment variable into a build-tool input across SwiftPM build systems.

## Which phases observe the environment?

SwiftPM compiles and executes package manifests using its current process
environment. The manifest context receives that snapshot, and the manifest cache
key includes all environment keys except a hard-coded non-cacheable set.
[Manifest context construction and execution](https://github.com/swiftlang/swift-package-manager/blob/17c2e6a797ec5a067f52c2bee2f386f3ba2ba277/Sources/PackageLoading/ManifestLoader.swift#L850-L914),
[manifest cache key](https://github.com/swiftlang/swift-package-manager/blob/17c2e6a797ec5a067f52c2bee2f386f3ba2ba277/Sources/PackageLoading/ManifestLoader.swift#L482-L492)

The practical propagation requirement is therefore:

| SwiftlyKit phase | Must receive a graph-affecting overlay? | Must receive dependency credentials? |
|---|---:|---:|
| Product/package inspection (`dump-package`) | Yes | Only if inspection fetches or loads remote graph data |
| Dependency/source-root inspection (`show-dependencies`) | Yes | Yes when it fetches or resolves |
| Explicit dependency resolution | Yes | Yes |
| Build | Yes | Yes if it can still fetch artifacts; otherwise not necessarily |
| Bin-path query for the completed build | Yes | Normally no, but it must use identical build options |
| Host-side strip/post-copy verification | No | No |

There is no sound “build-only” meaning for a value that can change
`Package.swift`. Inspection under environment A followed by build under
environment B can select a different product or graph than SwiftlyKit validated.
It can also invalidate source-root monitoring if the dependency set differs.

Conversely, the table does not imply that every secret should be sent to every
subprocess. Authentication values have a narrower job than graph configuration.
A safer API would separate credential delivery, package configuration, target
toolchain configuration, and host post-processing instead of treating them as
one overlay.

## Reproducibility, caching, and security

### Environment is part of SwiftPM's build identity, but only approximately

SwiftPM keys manifest caching by a filtered current environment and includes the
full current environment in the native build system's package-structure
signature. This acknowledges that environment changes may change both the
manifest result and build plan.
[Cacheable-environment filtering](https://github.com/swiftlang/swift-package-manager/blob/17c2e6a797ec5a067f52c2bee2f386f3ba2ba277/Sources/Basics/Environment/Environment.swift#L268-L282),
[package-structure signature](https://github.com/swiftlang/swift-package-manager/blob/17c2e6a797ec5a067f52c2bee2f386f3ba2ba277/Sources/Build/LLBuildCommands.swift#L418-L427)

That is an implementation safeguard, not a reproducibility guarantee. An
arbitrary value can still point to mutable external state, select a different
tool, or be consumed by scripts in ways the build graph cannot declare.

### Known credentials receive special treatment; arbitrary secrets do not

SwiftPM's recognized credential variables are deliberately classified as
non-cacheable, alongside other operation-specific environment values.
[SwiftPM configurable environment classification](https://github.com/swiftlang/swift-package-manager/blob/17c2e6a797ec5a067f52c2bee2f386f3ba2ba277/Sources/Basics/Environment/ConfigurableEnvVar.swift#L16-L68)

Plugin compilation persists its filtered compiler environment to a JSON state
file. Therefore a caller's custom secret under an unrecognized key is cacheable
by default and can be written into SwiftPM's build storage. Only keys on
SwiftPM's hard-coded non-cacheable list are removed.
[Plugin compilation state persistence](https://github.com/swiftlang/swift-package-manager/blob/17c2e6a797ec5a067f52c2bee2f386f3ba2ba277/Sources/SPMBuildCore/Plugins/DefaultPluginScriptRunner.swift#L388-L400),
[non-cacheable key list](https://github.com/swiftlang/swift-package-manager/blob/17c2e6a797ec5a067f52c2bee2f386f3ba2ba277/Sources/Basics/Environment/EnvironmentKey.swift#L37-L54)

This makes “all caller-provided values are sensitive” redaction insufficient.
SwiftlyKit can redact its own event stream, but it cannot promise that SwiftPM,
plugins, compilers, or build tools will not persist, transform, or print an
unknown value.

### Every manifest receives the environment snapshot

SwiftPM serializes the current process environment into the context used to
evaluate package manifests.
[SwiftPM manifest context model](https://github.com/swiftlang/swift-package-manager/blob/17c2e6a797ec5a067f52c2bee2f386f3ba2ba277/Sources/PackageLoading/ContextModel.swift#L19-L32)

As a result, placing a secret in the environment of the SwiftPM process exposes
it to executable manifests in the package graph. Plugin scripts also inherit the
environment. Persisted Keychain or `.netrc` credentials avoid exposing the raw
credential as a general manifest variable because SwiftPM reads them internally.
The official CI variables remain legitimate, but a library should not generalize
from those specifically handled keys to a promise that arbitrary secret
environment values are safe.

## SwiftlyKit decision implications

### What the evidence does not support

It does not support saying that environment values are categorically useless.
Authenticated dependency resolution and cross-compiled system-library lookup
are concrete counterexamples.

It also does not support keeping the current feature merely because those
counterexamples exist. `BuildRequest.environment` currently describes a
build/bin-path/strip overlay:

- too late for explicit dependency resolution and graph inspection;
- too broad for credentials;
- unnecessary for strip;
- capable of changing manifests after product validation;
- capable of overriding SwiftlyKit's selected tools; and
- unable to guarantee delivery to plugin tools across SwiftPM build systems.

### Adopted SwiftlyKit position

The implementation uses the smallest coherent workflow-level design:

1. `SwiftPMEnvironment` describes additions, sensitive additions, and inherited
   removals. It validates names and values before any workflow starts.
2. `prepare` captures the host environment once and stores the resolved snapshot
   privately in `LocalBuildEnvironment`. The fast track performs the same
   binding.
3. Package inspection, graph discovery, explicit resolution, build, bin-path
   lookup, clean, and reset use the identical snapshot. Swiftly preparation,
   downloads, stripping, copying, and verification do not receive caller
   changes.
4. Protected host, Swiftly, compiler, toolchain, and SDK values cannot replace
   the prepared environment. Inherited compiler and SDK overrides are removed.
5. Known SwiftPM credential variables and caller-marked sensitive values are
   redacted from retained results, diagnostics, and streamed events.

This design supports private dependency authentication, cross-compilation
`pkg-config`, trusted configurable manifests, plugins, and CI without requiring
an embedding application to mutate its global process environment. One public
value hides validation, propagation, invariant protection, snapshot lifetime,
and output redaction.

The security boundary remains exact: redaction protects SwiftlyKit output. A
trusted manifest, plugin, SwiftPM cache, or external tool can still consume or
persist supplied values. SwiftlyKit does not become a credential manager or a
general SwiftPM frontend. It adds no Keychain storage, credential broker,
persistent profile, typed `pkg-config` setting, or arbitrary SwiftPM arguments.

Adoption is desirable because the former `BuildRequest.environment` field
advertised incomplete, build-only behavior. Replacing it before compatibility
constraints exist fixes graph consistency while retaining SwiftlyKit's compact
scope.

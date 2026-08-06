# Triple Runtime Architecture Decision

**Target:** TripleApp and TripleCLI on macOS 26, Apple silicon

**Reference date:** 30 July 2026

**Decision question:** Should Triple keep its current macOS-hosted
Swiftly/Static Linux SDK build path and bootstrap Apple's Command Line Tools,
or move package inspection, building, and Linux runtime testing into a
Triple-managed Linux environment? If it moves, should it use Apple's
Virtualization framework, the `apple/containerization` Swift package, Apple's
`container` CLI, or some combination?

## Evidence vocabulary

| Label | Meaning |
|---|---|
| **Documented** | A first-party document or source file directly states or implements the behavior. |
| **Inference** | The conclusion follows from documented pieces, but the complete Triple integration has not been demonstrated. |
| **Recommendation** | A project decision proposed here. |

## Executive decision

1. **Correction: Apple virtualization can test Triple's exact x86-64 static
   Linux artifact on Apple silicon.** Virtualization.framework supports
   x86-64 Linux processes inside an ARM Linux VM. Apple explicitly says
   statically linked x86-64 binaries need no additional guest libraries.
   The artifact is executed under instruction translation, not on native
   x86-64 hardware.
   [Apple: Running Intel Binaries in Linux VMs](https://developer.apple.com/documentation/virtualization/running-intel-binaries-in-linux-vms)
2. **On Triple's macOS 26 baseline, exact x86-64 execution is not entirely
   zero-interaction.** If Rosetta is absent, macOS downloads it and
   interactively asks a person to authorize installation. In macOS 27, Intel
   Linux translation is integrated into the OS and no Rosetta installation
   is needed.
   [Apple: Rosetta availability and installation](https://developer.apple.com/documentation/virtualization/running-intel-binaries-in-linux-vms)
3. **Containerization and Virtualization are layers, not competing runtime
   choices.** `apple/containerization` is an open-source Swift package that
   uses the system Virtualization.framework on Apple silicon and adds OCI
   images, registry access, ext4 storage, a minimal guest init, process
   execution, I/O, signals, and Rosetta integration. Choosing the package
   means using both layers.
   [Apple Containerization README](https://github.com/apple/containerization/blob/ff44a5b683c80fceab875dba8a20ed24d7648c07/README.md#L6-L40)
4. **Triple should not depend on Apple's separate `container` CLI.** Its
   documented installation uses a signed package, an administrator password,
   files under `/usr/local`, and a system service. That recreates an external
   setup dependency.
   [Apple `container` installation](https://github.com/apple/container/blob/6e65319fe476ffe8db8ddaf828a537ed36fe2859/README.md#L14-L32)
5. **Strategic recommendation: pursue one Containerization-backed Linux
   execution runtime in TripleCore for both builds and runtime tests.** Put it
   behind a Triple-owned interface, pin the package version, and make
   Virtualization.framework an implementation detail.
6. **Delivery recommendation: do not replace the proven native build path
   before a focused prototype passes explicit gates.** While that work is in
   progress, a supported CLT prompt can make the current product usable. It is
   a transitional compatibility path, not the final zero-setup architecture.
   Trigger it at first package use or first build, with context, rather than
   unconditionally when Triple launches.

## What exact x86-64 testing can and cannot prove

### The exact artifact can run

**Documented:** Virtualization.framework runs x86-64 Linux binaries in an ARM
Linux distribution on Apple silicon. It does not boot an x86-64 Linux
distribution; translation applies to Intel user-space processes in an ARM
guest.
[Apple: Running Intel Binaries in Linux VMs](https://developer.apple.com/documentation/virtualization/running-intel-binaries-in-linux-vms)

Triple's x86 output is especially suitable. Swift's Static Linux SDK produces
a fully statically linked x86-64 ELF whose only runtime dependency is the
Linux system-call interface. Apple says Rosetta can run statically linked
x86-64 binaries without extra guest configuration; only dynamically linked
programs require matching shared libraries in the guest.
[Swift: Static Linux SDK](https://www.swift.org/documentation/articles/static-linux-getting-started.html#your-first-statically-linked-linux-program),
[Apple: static and dynamic Intel binaries](https://developer.apple.com/documentation/virtualization/running-intel-binaries-in-linux-vms)

**Conclusion:** Triple can copy the exact exported
`x86_64-unknown-linux-musl` executable into an ARM Linux runtime environment
and execute those same bytes through Rosetta. It does not need to substitute
an ARM build merely to perform a functional test.

### Containerization already wires up the translation path

The package exposes a `rosetta` option on its VM/container manager. Its macOS
backend:

- checks `VZLinuxRosettaDirectoryShare.availability`;
- invokes the system Rosetta installer when it is missing;
- adds the Rosetta VirtioFS share to the VM; and
- mounts the share in the guest and registers Rosetta through Linux `binfmt`.

[Containerization: host availability and installation](https://github.com/apple/containerization/blob/ff44a5b683c80fceab875dba8a20ed24d7648c07/Sources/Containerization/VZVirtualMachineInstance.swift#L368-L397),
[Containerization: VM share](https://github.com/apple/containerization/blob/ff44a5b683c80fceab875dba8a20ed24d7648c07/Sources/Containerization/VZVirtualMachineInstance.swift#L436-L462),
[Containerization: guest registration](https://github.com/apple/containerization/blob/ff44a5b683c80fceab875dba8a20ed24d7648c07/Sources/Containerization/Vminitd%2BRosetta.swift#L19-L34)

Apple's separate `container` tool demonstrates the same stack running an
`amd64` image on Apple silicon under Rosetta.
[Apple `container`: multi-platform image example](https://github.com/apple/container/blob/6e65319fe476ffe8db8ddaf828a537ed36fe2859/docs/how-to.md#build-and-run-a-multiplatform-image)

### The macOS 26 consent boundary

**Documented:** on macOS 26 and earlier, installing Rosetta is a one-time
operation per Mac. If it is missing, the framework downloads it and presents
an interactive authorization flow. The user can cancel, the host may not
support it, and network installation may fail. Starting in macOS 27, Intel
translation for Linux apps is included in macOS.
[Apple: Rosetta installation behavior](https://developer.apple.com/documentation/virtualization/running-intel-binaries-in-linux-vms)

This does **not** block a zero-setup first cross-compilation:

- ARM Linux can use the Static Linux SDK to emit both ARM64 and x86-64
  statically linked artifacts.
  [Swift: both Static Linux SDK targets](https://www.swift.org/documentation/articles/static-linux-getting-started.html#your-first-statically-linked-linux-program)
- Rosetta is needed only when Triple asks the Apple-silicon Mac to execute the
  x86-64 result.

**Recommendation:** make Rosetta an explicitly authorized capability of the
future “Test x86-64 artifact” action, not a prerequisite for opening a
project, building either architecture, or testing the ARM64 artifact.

### What the test does not prove

**Inference:** executing the exact binary under Apple's translation provides
strong evidence about ELF loading, Linux system calls, startup, arguments,
environment handling, networking, files, process exit, and application
behavior. It is not a measurement of native x86-64 performance, timing, or
microarchitecture behavior. Triple should label the result “x86-64 artifact
tested under Rosetta,” not “tested on x86-64 hardware.”

For native-hardware assurance, the remaining options are an x86-64 Linux
machine or remote build/test service. QEMU user-mode emulation could avoid
the host Rosetta installer, and QEMU officially supports x86-64 Linux
user-space emulation on another CPU architecture, but it would add another
large runtime, update, licensing, performance, and security responsibility to
Triple.
[QEMU: User Mode Emulation](https://www.qemu.org/docs/master/user/),
[QEMU: supported guest architectures](https://www.qemu.org/docs/master/about/emulation.html)

**Recommendation:** do not add QEMU in the first implementation. Rosetta is
the platform-native path on macOS 26; revisit QEMU only if user research shows
that declining Rosetta is common enough to justify maintaining a second
translator.

## Which Apple layer should Triple use?

### Layer map

```text
TripleApp / TripleCLI
        │
        ▼
TripleCore LinuxExecutionRuntime         ← Triple-owned stable interface
        │
        ▼
apple/containerization Swift package     ← pinned implementation dependency
        │
        ▼
Virtualization.framework                 ← system VM facility
        │
        ▼
ARM Linux microVM + vminitd
        ├── build profile
        ├── ARM64 runtime-test profile
        └── x86-64 runtime-test profile using Rosetta
```

Apple's `container` CLI and its system service are deliberately absent.

### Option assessment

| Choice | What Triple would receive | Project assessment |
|---|---|---|
| Raw Virtualization.framework only | VM boot, devices, networking, shares, sockets | Technically sufficient, but Triple would own the guest agent, process protocol, OCI/image handling, filesystems, Rosetta setup, lifecycle, and much more. Do not start here. |
| `apple/containerization` package | The above plus OCI, registries, ext4, lightweight VMs, guest processes, I/O/signals/events, and Rosetta | Best implementation starting point. Link it into Triple and hide it behind a narrow adapter. |
| `apple/container` CLI | A general external container product, services, CLI, image builder, networking | Reject as an end-user dependency because its install and service lifecycle contradict Triple's zero-setup goal. Useful only as a development reference. |
| Both package and raw framework code in Triple | Ability to bypass package abstractions selectively | Avoid initially. Use the framework indirectly through the package; introduce direct framework code only for a demonstrated missing capability. |
| Neither | Preserve the current macOS Swiftly/CLT build and add no Linux runtime | Lowest implementation cost, but cannot deliver the planned local Linux runtime-test feature and retains the CLT dependency. |

The first-party responsibilities support this distinction:

- Virtualization.framework documents how to supply a Linux kernel and initial
  RAM disk, allocate CPU and memory, and construct a VM.
  [Apple: Creating and Running a Linux Virtual Machine](https://developer.apple.com/documentation/virtualization/creating-and-running-a-linux-virtual-machine)
- Containerization adds OCI image management, registries, ext4 filesystems,
  VM/runtime management, guest process execution, and Rosetta.
  [Containerization capabilities](https://github.com/apple/containerization/blob/ff44a5b683c80fceab875dba8a20ed24d7648c07/README.md#L12-L32)
- Apple's `container` tool uses Containerization for its low-level image and
  process management, then adds XPC, launchd services, networking helpers,
  Keychain registry credentials, and a general CLI product.
  [Apple `container` technical overview](https://github.com/apple/container/blob/6e65319fe476ffe8db8ddaf828a537ed36fe2859/docs/technical-overview.md#L22-L47)

### API maturity

Containerization is pre-1.0. Its README says source stability is guaranteed
only within minor versions and recommends an `upToNextMinorVersion` constraint
for clients that do not want breaking package updates.
[Containerization project status](https://github.com/apple/containerization/blob/ff44a5b683c80fceab875dba8a20ed24d7648c07/README.md#L178-L184)

**Recommendation:** pin an exact reviewed release during the prototype and
early product work. Place all package types behind a deep Triple-owned
`LinuxExecutionRuntime` interface so version churn does not spread through
build policy, persistence, AppKit, or CLI presentation. Move to a bounded
minor-version constraint only after the package's compatibility record is
known.

Xcode 26 is required to build Containerization itself. Its current source
build also uses Apple's `container` CLI to build the static guest init inside
Linux. These are Triple release-engineering dependencies, not customer
runtime dependencies: Triple would ship a prebuilt, signed macOS product and
prebuilt guest assets.
[Containerization build requirements](https://github.com/apple/containerization/blob/ff44a5b683c80fceab875dba8a20ed24d7648c07/README.md#L50-L58),
[Containerization guest build](https://github.com/apple/containerization/blob/ff44a5b683c80fceab875dba8a20ed24d7648c07/README.md#L94-L115)

## Native CLT build versus a Linux appliance

| Concern | Current macOS Swiftly + CLT | Containerization-backed Linux appliance |
|---|---|---|
| First Linux build on a fresh Mac | Requires interactive CLT installation and license acceptance before SwiftPM can perform host work | Triple can automatically obtain its kernel, guest environment, exact Swift toolchain, and Static Linux SDK; no CLT is needed |
| Build semantics | SwiftPM and `Package.swift` execute as macOS host processes; target compilation emits Linux | SwiftPM and `Package.swift` execute on Linux; ARM64 output is Linux-to-Linux, x86-64 output remains a cross-build |
| Target versions | Triple already pins exact Swift and Static Linux SDK releases | Preserve the same exact selection, inside a digest/checksum-pinned guest |
| Host reproducibility | Target inputs are pinned, but the Apple-installed macOS SDK/CLT is outside Triple's versioned environment | Kernel, init, base image, Swift toolchain, SDK, and build command can all be pinned |
| Existing implementation | Already implemented throughout TripleCore and both frontends | Requires a substantial new runtime, provisioning, and execution adapter |
| Linux runtime testing | Requires a separate VM/container feature anyway | Reuses the same execution primitive and cached assets |
| Exact ARM64 test | Requires a Linux runtime | Runs natively in ARM Linux VM |
| Exact x86-64 test | Requires a Linux runtime plus translation/emulation or remote x86 | Runs under Rosetta; one-time interactive installation on macOS 26 |
| Isolation | User manifests, plugins, macros, and tests run on macOS with the user's access | Package-controlled code runs in a VM with narrow mounts |
| Private Git dependencies | Native SwiftPM can naturally use the user's macOS Git/SSH configuration through the configured home directory | Requires an explicit, secure credential bridge; credentials are not automatically present in the guest |
| Caches | Existing host scratch, module, dependency, and SDK caches | Needs persistent guest/image caches plus bounded host shares and eviction policy |
| First-build transfer | Swiftly, a toolchain, and the Static Linux SDK, plus CLT if absent | Linux kernel/init/base environment, a Linux Swift toolchain, and Static Linux SDK |
| App/CLI sharing | Existing TripleCore providers are shared | One serialized asset store and VM runtime must serve the App and embedded CLI safely |
| API stability | CLT and Swiftly are mature enough for the implemented path, though CLT lifecycle is Apple-controlled | System Virtualization API is established; Containerization package remains pre-1.0 |
| Product promise | “Triple guides you through installing Apple's developer tools” | “Open a package and build; Triple manages the Linux build environment” |

### Why the current path cannot silently bootstrap CLT

Apple documents `xcode-select --install` as the supported command-line entry
point. It opens a system dialog where the user clicks Install and accepts the
Command Line Tools license. The installed package supplies the macOS SDK,
manual pages, and toolchain binaries at
`/Library/Developer/CommandLineTools`. Apple also notes that Software Update
offers compatible CLT updates after macOS upgrades.
[Apple: Installing the command-line tools](https://developer.apple.com/documentation/xcode/installing-the-command-line-tools)

**Conclusion:** Triple can initiate and explain the supported Apple
installation, then detect completion. It cannot turn that documented flow
into a silent, app-owned bootstrap. It must handle cancellation, failed
download, incompatible state, and later system updates.

The current Triple architecture depends on this host environment in more than
one place:

- package inspection invokes `/usr/bin/xcrun swift package dump-package`;
  [Triple source: manifest inspection](../../TripleCore/Sources/TripleCore/SwiftPackageInspector/SwiftPackageInspector+Manifest.swift)
- environment preparation bootstraps Swiftly, installs the exact toolchain,
  and installs the matching Static Linux SDK;
  [Triple source: environment preparation](../../TripleCore/Sources/TripleCore/Toolchains/EnvironmentManager/EnvironmentManager+Preparation.swift)
- the build command runs the selected compiler through Swiftly.
  [Triple source: build command factory](../../TripleCore/Sources/TripleCore/Builds/SwiftPMBuildCommandFactory.swift)

Moving only manifest inspection from `xcrun swift` to the selected Swiftly
toolchain improves consistency but does not remove the host SDK requirement.
Swiftly's macOS implementation checks for the macOS SDK with `xcrun`, sets
`SDKROOT`, and uses the Command Line Tools SDK for custom toolchain locations.
[Swiftly macOS SDK prerequisite](https://github.com/swiftlang/swiftly/blob/d0795a223706ab274c0f361be38a5cef14c8d296/Sources/MacOSPlatform/MacOS.swift#L52-L83),
[Swiftly macOS command environment](https://github.com/swiftlang/swiftly/blob/d0795a223706ab274c0f361be38a5cef14c8d296/Sources/MacOSPlatform/MacOS.swift#L265-L342)

### Why a Linux appliance is more than a dependency workaround

Swift.org recommends SwiftPM for server applications and documents Linux
container builds as a standard way to produce Linux binaries from a Mac. It
publishes official Swift container images. The Static Linux SDK supports both
`aarch64-swift-linux-musl` and `x86_64-swift-linux-musl`.
[Swift server build guidance](https://www.swift.org/documentation/server/guides/building.html),
[Swift Static Linux SDK](https://www.swift.org/documentation/articles/static-linux-getting-started.html)

For Triple, the appliance would:

1. evaluate `Package.swift` on the platform the product targets;
2. resolve dependencies and run Linux tests in the same operating-system
   family as the output;
3. cross-build both static target architectures;
4. run the exact ARM64 output natively;
5. run the exact x86-64 output under Rosetta when authorized; and
6. keep executable package content outside the macOS process.

**Inference:** this provides a coherent foundation for the already-planned
runtime-testing feature and avoids building one VM subsystem for testing while
keeping a separate macOS toolchain subsystem solely for compilation.

## Project-specific engineering consequences

### Shared primitive, separate profiles

Use one implementation primitive but separate immutable policies:

```text
LinuxExecutionRuntime
├── build profile
│   ├── exact Swift toolchain + Static Linux SDK
│   ├── package source and dependency access
│   ├── persistent build/dependency caches
│   └── narrow artifact output
├── ARM64 runtime-test profile
│   ├── clean ephemeral root filesystem
│   └── exact ARM64 artifact
└── x86-64 runtime-test profile
    ├── clean ephemeral root filesystem
    ├── exact x86-64 artifact
    └── Rosetta capability on macOS 26
```

Do not reuse the builder's mutable root filesystem to test an artifact. The
builder contains compilers, caches, package sources, and possibly dependency
credentials; a runtime test should receive only the artifact and explicitly
declared arguments, environment, mounts, and network policy.

### Private dependencies are a release gate

Apple describes VM/container privacy as mounting only the host data each
workload needs.
[Apple `container` privacy model](https://github.com/apple/container/blob/6e65319fe476ffe8db8ddaf828a537ed36fe2859/docs/technical-overview.md#L22-L32)

**Inference:** the Linux guest will not automatically inherit macOS Keychain
items, SSH agent state, `~/.ssh`, `~/.netrc`, Git configuration, or corporate
certificate configuration. Triple currently executes SwiftPM with a macOS
home directory, so private dependency behavior will change.
[Triple source: controlled Swiftly environment](../../TripleCore/Sources/TripleCore/Toolchains/Swiftly/OfficialSwiftlyProvider/OfficialSwiftlyProvider+CommandEnvironment.swift)

**Recommendation:** design a credential broker, not a home-directory mount.
Pass only credentials approved for the current build, keep secrets out of
logs and persistent guest layers, and prefer short-lived HTTPS tokens or a
narrow SSH-agent-style forwarding protocol. Private HTTPS and SSH package
fixtures must pass before replacing the native path.

### Caching and first-build payload

Containerization manages OCI images, registries, ext4 filesystems, and
per-container VMs. A Linux kernel and guest init/root filesystem are still
required.
[Containerization capabilities and kernel requirement](https://github.com/apple/containerization/blob/ff44a5b683c80fceab875dba8a20ed24d7648c07/README.md#L12-L32),
[Containerization kernel](https://github.com/apple/containerization/blob/ff44a5b683c80fceab875dba8a20ed24d7648c07/README.md#L69-L92)

Triple should bundle a small reviewed kernel and init/guest agent so it can
boot without discovering build tools on the Mac. It can then transparently
download checksum- or digest-pinned Linux toolchain, Static Linux SDK, and
base-image assets as part of the first build. Swift's SDK installer requires
a published checksum for a remote SDK.
[Swift: SDK checksum requirement](https://www.swift.org/documentation/articles/static-linux-getting-started.html#installing-the-sdk)

**Inference:** the first build remains a substantial network operation. The
appliance adds kernel/init/base-image bytes but removes the CLT download.
Bundling every supported Swift release is not practical, and arbitrary
packages may need network dependency resolution anyway. The honest promise is
“no separately installed developer tools,” not “no download.”

Recommended persistent stores:

- immutable kernel and guest-agent versions;
- OCI content addressed by digest;
- exact Swift toolchain and SDK versions;
- a shared, content-addressed SwiftPM dependency cache;
- per-build writable scratch;
- ephemeral runtime-test filesystems; and
- explicit retention records so Triple removes only assets it owns.

The App and CLI must coordinate mutations to these stores. The existing
app-bundled CLI architecture makes a shared TripleCore service or lock-based
runtime feasible, but concurrent image unpack, cache eviction, and VM
lifecycle need deliberate serialization.

### Distribution and signing

Processes that create VMs need the public
`com.apple.security.virtualization` entitlement.
[Apple: Virtualization entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.virtualization),
[Apple: adding the entitlement](https://developer.apple.com/documentation/virtualization/adding-the-virtualization-entitlement-to-your-project)

TripleApp currently has Hardened Runtime enabled and App Sandbox disabled.
[Triple Xcode project](../../Triple.xcodeproj/project.pbxproj)

**Recommendation:** either sign both the app executable and the embedded real
CLI with the virtualization entitlement, or centralize VM ownership in one
signed app/helper process with authenticated IPC. The latter simplifies
shared cache ownership and concurrency but adds lifecycle and CLI-availability
complexity; choose it only if direct CLI VM ownership proves awkward.

Containerization is Apache-2.0, so it can be redistributed subject to its
license and notice obligations. Guest assets have their own licenses; release
engineering must inventory the Linux kernel, init, OCI layers, Swift
toolchain, Static Linux SDK, and included packages.
[Containerization license](https://github.com/apple/containerization/blob/ff44a5b683c80fceab875dba8a20ed24d7648c07/LICENSE)

## Recommended path

### Strategic destination

**Recommendation:** pursue the Containerization-backed Linux runtime. Use the
`apple/containerization` package directly from TripleCore; allow it to use
Virtualization.framework underneath; do not install or invoke Apple's
`container` CLI for customers; and do not begin by reimplementing the package
on raw Virtualization.framework.

This is preferable to making CLT a permanent prerequisite because it:

- satisfies the desired no-external-developer-tools first-build experience;
- gives package inspection and tests Linux semantics;
- pins more of the build host environment;
- isolates executable package content;
- directly enables the planned ARM64 and x86-64 runtime-test feature; and
- consolidates build and test infrastructure around one primitive.

It is not yet a proven Triple implementation. The pre-1.0 dependency,
credential bridge, cache model, first-build payload, VM lifecycle, and App/CLI
coordination are material engineering risks.

### Transitional CLT policy

If Triple must ship the current native backend before the appliance passes its
gates, add a narrow CLT preflight:

1. Detect whether a usable macOS SDK is present.
2. When the first selected package needs inspection/building, explain why the
   current backend needs Apple's tools.
3. Only after the user's explicit action, invoke the documented
   `xcode-select --install` flow.
4. Observe completion or cancellation and retry inspection.
5. Reassess after macOS upgrades and provide an actionable update state.

Do **not** trigger the system installer on an unconditional application
launch. The user may only be opening Triple to inspect existing history or
settings, and an unexplained system license dialog would be surprising.

This flow is a usability repair, not “zero setup”: Apple, not Triple, owns the
download, license, authorization, and update lifecycle.

### Proof before migration

Build one focused, disposable prototype before restructuring production
TripleCore. It must use the same signed-distribution conditions expected for
Triple, not only `swift run` from a developer checkout.

Go/no-go gates:

1. A signed, virtualization-entitled macOS executable boots a pinned ARM
   Linux environment on macOS 26 with Xcode and CLT unavailable.
2. It mounts a real Swift server fixture, evaluates its manifest, resolves
   dependencies, and returns logs and structured exit status.
3. It builds the exact ARM64 and x86-64 static artifacts.
4. It executes the exact ARM64 artifact natively.
5. It executes the exact x86-64 artifact through Rosetta, correctly handling
   installed, not-installed, cancelled, offline, and unsupported states.
6. It repeats builds from a warm persistent cache and survives cancellation,
   app termination, corrupt downloads, and cache eviction.
7. HTTPS-token and SSH private-package fixtures work without mounting the
   user's whole home or writing credentials to guest layers/logs.
8. TripleApp and the embedded TripleCLI can share assets without concurrent
   corruption.
9. Runtime-test environments are fresh and cannot modify build caches or
   credential state.
10. Build output and runtime behavior are compared with the current backend
    across representative Swift-on-server fixtures.

If these gates pass, introduce a stable `LinuxExecutionRuntime` boundary,
migrate inspection/build/test operations incrementally, and remove the native
Swiftly/CLT backend only after feature parity. If they fail on a fundamental
platform limitation, retain the native backend and make the supported CLT
installation an explicit product prerequisite.

## Final assessment

The best path is not “Containerization instead of Virtualization.” It is:

> **Triple-owned runtime API → pinned Apple Containerization package →
> system Virtualization.framework.**

The best product strategy is not an immediate rewrite, and it is not a
permanent CLT bootstrap:

> **Use a contextual CLT installer only to support the existing backend while
> proving and then migrating toward one Linux appliance that powers both
> compilation and runtime testing.**

The exact x86-64 artifact is testable in that appliance today. On macOS 26,
the user must authorize Rosetta once to perform that particular test; the
first cross-compilation itself does not require Rosetta, Xcode, or CLT.

## Primary source inventory

### Apple

- [Virtualization framework](https://developer.apple.com/documentation/virtualization)
- [Creating and Running a Linux Virtual Machine](https://developer.apple.com/documentation/virtualization/creating-and-running-a-linux-virtual-machine)
- [Running Intel Binaries in Linux VMs](https://developer.apple.com/documentation/virtualization/running-intel-binaries-in-linux-vms)
- [Virtualization entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.virtualization)
- [Installing the command-line tools](https://developer.apple.com/documentation/xcode/installing-the-command-line-tools)
- [Apple Containerization](https://github.com/apple/containerization)
- [Apple `container`](https://github.com/apple/container)

### Swift project

- [Getting Started with the Static Linux SDK](https://www.swift.org/documentation/articles/static-linux-getting-started.html)
- [Swift server build guidance](https://www.swift.org/documentation/server/guides/building.html)
- [Swiftly](https://github.com/swiftlang/swiftly)

### Emulator alternative

- [QEMU User Mode Emulation](https://www.qemu.org/docs/master/user/)
- [QEMU emulation targets](https://www.qemu.org/docs/master/about/emulation.html)

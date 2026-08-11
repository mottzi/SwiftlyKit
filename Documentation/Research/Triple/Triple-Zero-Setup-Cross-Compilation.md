# Triple: Zero-Setup Cross-Compilation on a Fresh Mac

**Target:** macOS 26 on Apple silicon

**Reference date:** 30 July 2026

**Question:** Can TripleApp and TripleCLI perform their first cross-compilation
without the user installing or configuring Xcode, Command Line Tools, Swiftly,
a Swift toolchain, or a Static Linux SDK?

## Evidence vocabulary

| Label | Meaning |
|---|---|
| **Documented** | A first-party document or source file directly states or implements the behavior. |
| **Inference** | A conclusion follows from the documented pieces, but no source promises Triple's complete design. |
| **Recommendation** | A proposed Triple product or architecture decision. |

“Zero setup” in this note means no Terminal commands, external installer,
administrator workflow, or license dialog initiated by the user. Triple may
download and cache its own verified build resources while showing progress.
It cannot mean “no network transfer”: a package may itself have remote
dependencies, and supporting arbitrary exact Swift releases requires
version-specific resources.

## Executive answer

1. **Full Xcode is not an end-user requirement.** Apple offers Command Line
   Tools as the smaller alternative and says that package contains the macOS
   SDK and relevant toolchain binaries. Building Triple itself from source
   still requires Xcode; running a distributed Triple binary does not.
   [Apple: Installing the command-line tools](https://developer.apple.com/documentation/xcode/installing-the-command-line-tools)
2. **Command Line Tools are a hard requirement of Triple's current
   macOS-hosted build architecture.** This is not caused only by Triple's
   explicit `xcrun swift` inspection command. Swiftly's macOS implementation
   itself checks for a macOS SDK with `xcrun`, derives `SDKROOT` from `xcrun`,
   and, for custom toolchain locations, directly uses the installed Command
   Line Tools SDK and `libxcrun`.
   [Swiftly source: SDK prerequisite](https://github.com/swiftlang/swiftly/blob/d0795a223706ab274c0f361be38a5cef14c8d296/Sources/MacOSPlatform/MacOS.swift#L52-L83),
   [Swiftly source: toolchain environment](https://github.com/swiftlang/swiftly/blob/d0795a223706ab274c0f361be38a5cef14c8d296/Sources/MacOSPlatform/MacOS.swift#L265-L342)
3. **Changing Triple from `xcrun swift` to a Swiftly-selected macOS toolchain
   does not remove the CLT dependency.** It removes one direct coupling but
   leaves Swiftly and macOS-hosted SwiftPM dependent on the macOS SDK.
4. **Triple can initiate Apple's CLT installer, but cannot provide a
   zero-interaction CLT bootstrap through a documented public mechanism.**
   Apple's supported `xcode-select --install` flow presents a system dialog in
   which the user clicks Install and accepts Apple's license. Swiftly's own
   first-party source says there is no simple shell script for installing the
   developer tools.
   [Apple: installer interaction](https://developer.apple.com/documentation/xcode/installing-the-command-line-tools),
   [Swiftly source](https://github.com/swiftlang/swiftly/blob/d0795a223706ab274c0f361be38a5cef14c8d296/Sources/MacOSPlatform/MacOS.swift#L63-L74)
5. **Fully removing Xcode and CLT from the end-user path is technically
   viable on Triple's macOS 26 / Apple-silicon baseline.** Run all
   package-dependent SwiftPM work in a Triple-managed Linux microVM:
   manifest evaluation, dependency resolution, tests, target builds, and
   stripping. The macOS process then only orchestrates the VM and assembles
   returned artifacts.
6. **Apple's system Virtualization framework is sufficient.** It can boot a
   supplied Linux kernel, provide NAT networking, share host directories
   through VirtioFS, and communicate over virtio sockets. The process needs
   the public `com.apple.security.virtualization` entitlement, not Xcode or
   CLT on the customer's Mac.
   [Apple: Linux VM](https://developer.apple.com/documentation/virtualization/creating-and-running-a-linux-virtual-machine),
   [virtualization entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.virtualization),
   [NAT networking](https://developer.apple.com/documentation/virtualization/vznatnetworkdeviceattachment),
   [VirtioFS](https://developer.apple.com/documentation/virtualization/vzvirtiofilesystemdeviceconfiguration),
   [virtio sockets](https://developer.apple.com/documentation/virtualization/vzvirtiosocketdeviceconfiguration)
7. **Recommendation:** make the Linux build appliance Triple's only shipped
   package-execution architecture. Do not make CLT installation part of
   bootstrap and do not retain a native fallback that silently restores the
   dependency.

## Requirement matrix

| Operation | Current macOS-hosted path | Proposed Linux appliance |
|---|---:|---:|
| Launch a distributed Triple app or CLI | No Xcode/CLT | No Xcode/CLT |
| Read `swift-tools-version` as text | No Xcode/CLT | No Xcode/CLT |
| Evaluate `Package.swift` | macOS SDK/CLT | Linux toolchain in guest |
| Resolve package dependencies | macOS SwiftPM/CLT | Linux SwiftPM in guest |
| Install/select exact Swift toolchain | macOS Swiftly/CLT | Guest-managed toolchain or exact OCI image |
| Install/use Static Linux SDK | macOS SwiftPM/CLT | Linux SwiftPM in guest |
| Build Linux ARM64 or x86-64 artifact | macOS SwiftPM/CLT | Linux SwiftPM in guest |
| Run server-package tests | Current macOS host tests need CLT | Linux guest tests need no CLT |
| Build TripleApp from source | Full Xcode | Full Xcode; developer-only |

## Why the current native path needs the macOS SDK

### The Static Linux SDK is the target environment, not the host environment

The Static Linux SDK supplies the target sysroots and libraries needed to emit
fully static Linux executables. Swift.org says it works from any platform
supported by the Swift compiler and package manager and demonstrates both
`x86_64-swift-linux-musl` and `aarch64-swift-linux-musl` outputs.
[Swift.org: Getting Started with the Static Linux SDK](https://www.swift.org/documentation/articles/static-linux-getting-started.html)

That does not make the Swift compiler, SwiftPM, package manifests, build-tool
plugins, or macros into Linux processes when `swift build` itself is running
on macOS. They still have host-side work.

### `Package.swift` is compiled and executed on the host

SwiftPM does not parse a manifest as inert configuration. Its manifest loader:

1. constructs a compiler command for the host toolchain;
2. on macOS, sets a macOS host target;
3. compiles `Package.swift` to a temporary executable; and
4. runs that executable to obtain the package description.

This is directly implemented in SwiftPM's manifest loader.
[SwiftPM source: macOS host target and compilation](https://github.com/swiftlang/swift-package-manager/blob/5d0f6086cd9af7d9097e31a785d39a72955dee9f/Sources/PackageLoading/ManifestLoader.swift#L747-L829),
[SwiftPM source: executing the manifest](https://github.com/swiftlang/swift-package-manager/blob/5d0f6086cd9af7d9097e31a785d39a72955dee9f/Sources/PackageLoading/ManifestLoader.swift#L831-L909)

SwiftPM's default macOS host SDK discovery is equally explicit: unless an SDK
path is supplied through the environment, it runs
`/usr/bin/xcrun --sdk macosx --show-sdk-path`, and the manifest loader passes
that SDK to the compiler.
[SwiftPM source: macOS SDK discovery](https://github.com/swiftlang/swift-package-manager/blob/5d0f6086cd9af7d9097e31a785d39a72955dee9f/Sources/PackageModel/SwiftSDKs/SwiftSDK.swift#L577-L631),
[SwiftPM source: manifest SDK flag](https://github.com/swiftlang/swift-package-manager/blob/5d0f6086cd9af7d9097e31a785d39a72955dee9f/Sources/PackageLoading/ManifestLoader.swift#L950-L970)

On a macOS host, that temporary executable needs the macOS SDK and host linker
environment. The Linux SDK cannot replace them because it produces a Linux
executable, which macOS cannot run directly.

### Swiftly confirms the dependency

The current macOS Swiftly implementation:

- calls `/usr/bin/xcrun --show-sdk-path --sdk macosx` before installing a
  toolchain and warns that the macOS SDK is required;
- sets `SDKROOT` from `xcrun` for tools such as `clang++`, because standard
  libraries such as libc++ are not in the downloaded Swift toolchain; and
- when toolchains live outside the standard directory, requires
  `/Library/Developer/CommandLineTools`, then links its SDK and
  `libxcrun.dylib` into Swiftly's compatibility developer directory.

[Swiftly source: prerequisite](https://github.com/swiftlang/swiftly/blob/d0795a223706ab274c0f361be38a5cef14c8d296/Sources/MacOSPlatform/MacOS.swift#L52-L83),
[Swiftly source: `SDKROOT` and CLT compatibility directory](https://github.com/swiftlang/swiftly/blob/d0795a223706ab274c0f361be38a5cef14c8d296/Sources/MacOSPlatform/MacOS.swift#L265-L342)

Swift.org separately says Xcode is not required to install an open-source
macOS toolchain, while warning that SwiftPM functionality may be limited when
Xcode is absent. That distinction is consistent with CLT being sufficient:
full Xcode is optional, but a usable macOS SDK is not.
[Swift.org: macOS package installer](https://www.swift.org/install/macos/package_installer/)

**Conclusion:** replacing Triple's current
`/usr/bin/xcrun swift package dump-package` call with `swiftly run swift`
would improve toolchain consistency, but it would not satisfy the stated
product requirement.

## Why CLT should not be Triple's mandatory bootstrap

### The supported install is interactive

Apple documents `xcode-select --install` as the command-line entry point. It
opens a system dialog; the user must click Install and agree to the Command
Line Tools license. On a fresh macOS install, invoking developer-tool commands
may trigger the same prompt.
[Apple: Installing the command-line tools](https://developer.apple.com/documentation/xcode/installing-the-command-line-tools)

Triple could trigger this installer as a diagnostic convenience for
developers, but it cannot honestly describe that flow as zero-setup or
guarantee completion in an unattended CLI session. It should not be part of
Triple's shipped build path.

### Triple should not redistribute Apple's SDK

Bundling selected pieces of CLT or a copied macOS SDK is not an acceptable
shortcut. Apple's Xcode and Apple SDKs Agreement defines the macOS SDK as
Apple-proprietary software, grants an internal-use license, permits copies
only as an entire package for permitted use, prohibits separately using the
SDKs, and prohibits redistribution unless Apple expressly permits it.
[Apple: Xcode and Apple SDKs Agreement, §§2.2, 2.5, 2.7](https://www.apple.com/legal/sla/docs/xcode.pdf)

This is a product constraint, not merely a technical inconvenience. Triple
should not copy a macOS SDK, `libxcrun`, or linker payload into its app or its
own download service. This note is technical research, not legal advice; final
distribution materials still need license review.

### App Store rules also favor removing optional system dependencies

Apple's Mac App Store rules say apps must be self-contained and may not depend
on optionally installed technologies. They also restrict downloading or
executing code that introduces or changes app functionality, with a limited
exception for certain code-development/education apps.
[Apple: App Review Guidelines, §§2.4.5 and 2.5.2](https://developer.apple.com/app-store/review/guidelines/)

This does not decide Triple's review outcome. It means both a CLT dependency
and a downloadable build appliance require an explicit distribution review.
Developer ID distribution is the lower-risk initial channel for a developer
tool of this shape.

## Architecture that removes CLT completely

### Product boundary

**Recommendation:** package execution belongs inside a Linux isolation
boundary. Triple's macOS process should never compile or execute a user's
manifest, plugin, macro, test, or server program.

The complete operation becomes:

```text
TripleApp / TripleCLI
  → parse swift-tools-version as text
  → select an exact official Swift + Static Linux SDK pair
  → start Triple's Linux build appliance
  → inspect Package.swift in Linux
  → resolve dependencies in Linux
  → test in Linux, when requested
  → build and strip the static Linux artifact in Linux
  → return logs, metadata, and artifact files
  → assemble and index the artifact on macOS
```

The early `swift-tools-version` directive is deliberately textual, so Triple
can select a compatible guest environment before evaluating the manifest.
The authoritative product/target graph then comes from Linux SwiftPM, which is
also the environment relevant to a Swift-on-server package.

### Why macOS 26 already provides the required host facility

Apple's Virtualization framework can:

- boot a caller-supplied Linux kernel and optional initial RAM disk;
- expose outside networking through NAT;
- expose selected host directories through VirtioFS; and
- provide host/guest command and event transport through virtio sockets.

[Apple: Linux VM construction](https://developer.apple.com/documentation/virtualization/creating-and-running-a-linux-virtual-machine),
[NAT attachment](https://developer.apple.com/documentation/virtualization/vznatnetworkdeviceattachment),
[VirtioFS configuration](https://developer.apple.com/documentation/virtualization/vzvirtiofilesystemdeviceconfiguration),
[virtio socket device](https://developer.apple.com/documentation/virtualization/vzvirtiosocketdevice)

NAT specifically does not require the separate `com.apple.vm.networking`
entitlement. The process that creates the VM does require
`com.apple.security.virtualization`.
[Apple: NAT entitlement behavior](https://developer.apple.com/documentation/virtualization/vznatnetworkdeviceattachment),
[Apple: virtualization entitlement](https://developer.apple.com/documentation/virtualization/adding-the-virtualization-entitlement-to-your-project)

### Apple Containerization is an implementation accelerator, not a user dependency

Apple's open-source Containerization package is a strong starting point:

- its macOS backend uses Virtualization.framework directly and says no extra
  binaries are required;
- it manages OCI images, registries, ext4 filesystems, lightweight VMs, and
  guest processes;
- its `vminitd` guest agent exposes process I/O, signals, and events over
  vsock; and
- its example directly pulls an OCI image and mounts a host directory into a
  container.

[Apple Containerization design](https://github.com/apple/containerization/blob/ff44a5b683c80fceab875dba8a20ed24d7648c07/README.md#L12-L40),
[direct `cctl run` example](https://github.com/apple/containerization/blob/ff44a5b683c80fceab875dba8a20ed24d7648c07/Sources/cctl/RunCommand.swift#L79-L132),
[Virtualization-backed shares and NAT](https://github.com/apple/containerization/blob/ff44a5b683c80fceab875dba8a20ed24d7648c07/Sources/Containerization/VZVirtualMachineInstance.swift#L413-L534),
[example entitlement](https://github.com/apple/containerization/blob/ff44a5b683c80fceab875dba8a20ed24d7648c07/signing/vz.entitlements)

Apple's `sandboxy` example is a close first-party proof of the proposed product
shape. It is one command with no daemon; boots a microVM; automatically
downloads and caches a kernel, init image, OCI root filesystem, and installed
toolchain; and shares the workspace with VirtioFS. Triple's workload is
narrower than this general coding-agent example. The example executable asks
only for the virtualization entitlement. This strongly supports an in-process
integration without a macOS administrator or installer step; guest processes
running as Linux `root` do not gain macOS root privileges.
[Apple Containerization: `sandboxy` design and cache](https://github.com/apple/containerization/blob/ff44a5b683c80fceab875dba8a20ed24d7648c07/examples/sandboxy/README.md#L39-L78),
[`sandboxy` entitlement](https://github.com/apple/containerization/blob/ff44a5b683c80fceab875dba8a20ed24d7648c07/examples/sandboxy/sandboxy.entitlements)

Do **not** make Apple's separate `container` CLI a prerequisite. Its official
installer writes under `/usr/local`, asks for an administrator password, and
requires the user to start a system service. That recreates exactly the
external setup Triple is intended to eliminate.
[Apple `container`: installation](https://github.com/apple/container/blob/6e65319fe476ffe8db8ddaf828a537ed36fe2859/README.md#L14-L32)

Instead, either:

1. link a pinned Containerization package release and ship Triple's
   release-built kernel/init filesystem/guest agent; or
2. implement the smaller single-purpose appliance directly on
   Virtualization.framework.

Containerization's API remains pre-1.0 and only promises source stability
within minor versions, so Triple must pin it and keep the VM boundary behind a
deep internal interface.
[Apple Containerization: project status](https://github.com/apple/containerization/blob/ff44a5b683c80fceab875dba8a20ed24d7648c07/README.md#L178-L184)

Xcode 26 is required to **build** Containerization and Triple's macOS binary.
That is a release-engineering requirement, not a runtime requirement for the
customer receiving the already-built app and CLI.

### Guest environment choices

Two viable guest provisioning strategies exist:

1. **Exact official Swift OCI image.** Pull a digest-pinned official Swift
   builder image, then install the matching Static Linux SDK inside it.
   Swift's first-party Docker repository identifies the Docker Official Image
   and provides builder images containing the compiler. The official image
   catalog lists both `amd64` and `arm64v8`.
   [Swift Docker images](https://github.com/swiftlang/swift-docker/blob/cdfdf30bef6f1529ad34662274db00781d87ab61/README.md#L1-L49),
   [Docker Official Image architectures](https://hub.docker.com/_/swift)
2. **Stable Triple appliance plus guest Swiftly.** Ship one minimal supported
   Linux root filesystem, run Swiftly inside the guest, and cache exact Linux
   toolchains and Static Linux SDKs in guest-owned storage.
   Swiftly officially supports Linux and macOS.
   [Swiftly](https://github.com/swiftlang/swiftly)

The OCI-image approach is simpler for a first implementation because the
distro dependencies of the exact compiler are already captured. The stable
appliance approach can reduce repeated base-image storage later.

In either case, the existing Swift.org release metadata, exact-version policy,
Static Linux SDK URL, and published checksum remain valuable. They move into
the guest environment rather than being discarded.

### Filesystem and security model

`Package.swift`, build-tool plugins, macros, tests, and build scripts are
executable code. The VM is therefore a security improvement over running them
as macOS processes.

Recommended mounts:

- package source: read-only VirtioFS;
- dependency cache and Swift toolchains: Triple-owned persistent guest
  storage;
- `.build` scratch: Triple-owned writable storage, not the source tree;
- artifact exchange: one narrow Triple-owned writable share.

Apple documents that VirtioFS applies the effective host user's permissions,
does not grant access to host files the user cannot access, and ignores guest
attempts to change host UID/GID ownership.
[Apple: VirtioFS permission behavior](https://developer.apple.com/documentation/virtualization/vzvirtiofilesystemdevice)

For a future sandboxed TripleApp, package access should continue to originate
from an `NSOpenPanel` and a security-scoped bookmark. Apple documents that
user-selected folder access extends recursively and that executable output
requires the corresponding user-selected executable entitlement.
[Apple: Accessing files from the macOS App Sandbox](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)

### Tests and package semantics

Moving inspection to Linux can change manifests that contain host conditionals
such as `#if os(macOS)` or `#if os(Linux)`. For a product explicitly targeting
Swift-on-server Linux artifacts, Linux evaluation is the more relevant truth.

Likewise, **Test & Build** should run Linux preflight tests in the appliance.
The current macOS-host-test implementation should be replaced, not retained as
a fallback, because even an optional macOS SwiftPM invocation would make CLT a
runtime prerequisite for part of Triple.

The Static Linux SDK can emit both ARM64 and x86-64 artifacts from a supported
host, so an ARM64 Linux VM can preserve both Triple build architectures.
Executing x86-64 tests inside that ARM64 guest would require emulation.
Triple can initially run Linux ARM64 tests and still cross-build x86-64, or
later bundle a separately licensed emulator. Rosetta must not become another
mandatory external bootstrap.

## App, CLI, and distribution implications

### Signing and entitlements

- Every macOS executable that directly creates a VM needs
  `com.apple.security.virtualization`. Sign TripleApp and TripleCLI
  accordingly, or centralize VM ownership in one signed helper with a narrow
  IPC interface.
- Direct Developer ID distribution should sign every bundled host executable,
  enable hardened runtime, notarize the product, and staple the ticket. Apple
  requires Developer ID, hardened runtime, secure timestamps, and valid code
  signatures for notarization.
  [Apple: Notarizing macOS software](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- The current TripleApp target is not sandboxed. A Mac App Store edition would
  need App Sandbox, outgoing-network, user-selected file access, and a review
  of downloaded toolchain/image behavior. App Sandbox is mandatory for the
  Mac App Store.
  [Apple: App Sandbox](https://developer.apple.com/documentation/security/app-sandbox)

### Bundle versus managed download

For the best first-run experience:

- bundle a small, versioned Linux kernel and init filesystem/guest agent so
  the VM can boot immediately;
- automatically download exact toolchain and SDK payloads as part of the
  build operation, with clear progress and cancellation;
- pin every OCI image by digest and verify every Swift.org checksum;
- keep immutable, versioned caches and remove only resources owned by Triple;
- never build the guest kernel or agent on the customer's Mac.

The payload is material. As of the reference date, the official Swift 6.3.3
Ubuntu 24.04 ARM64 toolchain archive is 1,054,239,814 bytes and its matching
Static Linux SDK archive is 304,974,043 bytes: approximately 1.36 GB
(1.27 GiB) compressed before the kernel, init filesystem, and other appliance
content. Those sizes come from the `Content-Length` headers on the
[official toolchain archive](https://download.swift.org/swift-6.3.3-release/ubuntu2404-aarch64/swift-6.3.3-RELEASE/swift-6.3.3-RELEASE-ubuntu24.04-aarch64.tar.gz)
and
[official Static Linux SDK archive](https://download.swift.org/swift-6.3.3-release/static-sdk/swift-6.3.3-RELEASE/swift-6.3.3-RELEASE_static-linux-0.1.0.artifactbundle.tar.gz).

Bundling every supported Swift toolchain is not practical and would still not
make arbitrary packages offline because their dependencies may be remote.
The honest promise is:

> Install Triple, open a package, and build. Triple obtains and manages
> everything else.

### Licensing inventory

Release engineering must inventory the Linux kernel, init system, Swift
toolchain/image layers, Static Linux SDK, and all guest packages. Apple
Containerization is Apache-2.0 and its license requires preservation of the
license and applicable notices when redistributed.
[Apple Containerization license](https://github.com/apple/containerization/blob/ff44a5b683c80fceab875dba8a20ed24d7648c07/LICENSE)

OCI images contain more than the top-level Swift project, so their complete
package licenses and notices must travel with the distributed or cached
appliance as required. A Linux kernel binary also needs its applicable source
and license compliance handled by release engineering.

### Mac App Store uncertainty

Apple's guideline against downloaded executable code turns on whether a
download introduces or changes the app's features. Triple's argument is that
the build feature is fixed in the reviewed binary and the downloaded
toolchain is user-facing developer content executed inside a VM. The guideline
does not explicitly guarantee acceptance for this case.
[Apple: App Review Guideline 2.5.2](https://developer.apple.com/app-store/review/guidelines/)

**Recommendation:** ship the first appliance-backed release through Developer
ID distribution, document all downloaded components, and treat Mac App Store
support as a separate approval investigation rather than constraining the
core architecture prematurely.

## Recommended Triple decision

Adopt this product invariant:

> A distributed TripleApp or TripleCLI must complete package inspection and a
> Linux cross-build on a fresh supported Mac without Xcode, Command Line
> Tools, Swiftly, or any other developer software installed on macOS.

Implementation direction:

1. Introduce a shared `BuildRuntime` boundary in TripleCore.
2. Implement a Linux-appliance runtime behind that boundary.
3. Move manifest inspection, dependency resolution, environment preparation,
   tests, build, and strip into the guest as one coherent pipeline.
4. Preserve artifact assembly, indexing, persistence, and UI/CLI presentation
   on macOS.
5. Use the same runtime and managed cache for TripleApp and TripleCLI.
6. Remove direct `xcrun` calls from the product path.
7. Remove the native Swiftly build backend after the appliance reaches
   functional parity. Swiftly may remain an implementation option *inside the
   Linux guest*, but no macOS Swiftly, SwiftPM, or developer-tool invocation
   belongs in the shipped workflow.

The first architectural proof should run on a macOS 26 Apple-silicon machine
where `/Library/Developer/CommandLineTools` and Xcode are absent. It should
inspect a real server package, resolve dependencies, build both Static Linux
SDK architectures, return an artifact, and repeat from a warm cache. This is
the gate that proves the product promise; replacing only the inspection
command does not.

## Primary source inventory

### Apple

- [Installing the command-line tools](https://developer.apple.com/documentation/xcode/installing-the-command-line-tools)
- [Xcode and Apple SDKs Agreement](https://www.apple.com/legal/sla/docs/xcode.pdf)
- [Creating and Running a Linux Virtual Machine](https://developer.apple.com/documentation/virtualization/creating-and-running-a-linux-virtual-machine)
- [`com.apple.security.virtualization`](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.virtualization)
- [Adding the Virtualization Entitlement](https://developer.apple.com/documentation/virtualization/adding-the-virtualization-entitlement-to-your-project)
- [`VZNATNetworkDeviceAttachment`](https://developer.apple.com/documentation/virtualization/vznatnetworkdeviceattachment)
- [`VZVirtioFileSystemDeviceConfiguration`](https://developer.apple.com/documentation/virtualization/vzvirtiofilesystemdeviceconfiguration)
- [`VZVirtioFileSystemDevice`](https://developer.apple.com/documentation/virtualization/vzvirtiofilesystemdevice)
- [`VZVirtioSocketDevice`](https://developer.apple.com/documentation/virtualization/vzvirtiosocketdevice)
- [Apple Containerization](https://github.com/apple/containerization)
- [Apple `container`](https://github.com/apple/container)
- [Notarizing macOS software](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)

### Swift project

- [Swiftly](https://github.com/swiftlang/swiftly)
- [Swift Package Manager manifest loader](https://github.com/swiftlang/swift-package-manager/blob/5d0f6086cd9af7d9097e31a785d39a72955dee9f/Sources/PackageLoading/ManifestLoader.swift)
- [Getting Started with the Static Linux SDK](https://www.swift.org/documentation/articles/static-linux-getting-started.html)
- [Swift installation for macOS](https://www.swift.org/install/macos/)
- [Swift Docker images](https://github.com/swiftlang/swift-docker)

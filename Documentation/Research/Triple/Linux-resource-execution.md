# Linux execution of exported resources

Reference date: 10 October 2026.

The library source revision was `513be38e4dcb137c7cd19cb76a101d387fd12c4c`.
All four stripped release exports ran successfully on an actual Ubuntu 24.04.4
Linux host after Triple removed their original scratch storage. Each executable
loaded its own resource and a resource from its linked library dependency.

| Toolchain | Linux architecture | Resource layout | Execution | Result |
| --- | --- | --- | --- | --- |
| Swift 6.3.3 | x86_64 | `.resources` | Native x86_64 Linux | Exit 0; exact output; empty stderr |
| Swift 6.3.3 | aarch64 | `.resources` | QEMU user mode on x86_64 Linux | Exit 0; exact output; empty stderr |
| Swift 6.4.0 | x86_64 | `.bundle` | Native x86_64 Linux | Exit 0; exact output; empty stderr |
| Swift 6.4.0 | aarch64 | `.bundle` | QEMU user mode on x86_64 Linux | Exit 0; exact output; empty stderr |

The ARM64 checks use Linux user-mode CPU emulation. They establish that the
AArch64 executable and its resources run on Linux through QEMU; they do not
establish native ARM hardware behavior. The host kernel was
`6.8.0-142-generic`, architecture `x86_64`.

Every binary was ELF64 for the requested architecture. `readelf` found no
`INTERP` program header or `NEEDED` dynamic library entry. Both messages matched
byte for byte:

```text
Triple cross-compilation fixture
Triple executable resource fixture
```

## Library checks

The command `swift test` passed the ordinary library suite on Apple Swift 6.4,
with the opt-in host-cache and acceptance cases disabled. The last output line was:

```text
Test run with 352 tests in 46 suites passed after 2.457 seconds.
```

The full suite was then repeated with every opt-in case enabled:

```sh
TRIPLE_RUN_ACCEPTANCE=1 TRIPLE_TEST_HOST_CACHE=1 swift test > /tmp/triple-0.7.0-linux-proof/library-tests-swift-6.4-acceptance.log 2>&1
```

It exited 0 with no skipped tests. The relevant final output was:

```text
Test "Cancellation terminates child processes in the subprocess group" passed after 1.010 seconds.
Test "SwiftPM accepts one trait configuration for inspection, graph discovery, resolution, and build" passed after 5.699 seconds.
Test "Cached dependency manifests preserve SDK recovery and invalidate changed manifests" passed after 12.775 seconds.
Test "A second identical build preserves artifact identity" passed after 19.101 seconds.
Test "Cross-compilation package builds verified ARM64 and x86-64 executables" with 4 test cases passed after 50.058 seconds.
Test run with 352 tests in 46 suites passed after 50.061 seconds.
```

The four parameterized cross-compilation cases each build both architectures,
covering eight debug/release build/export combinations. The cancellation test
starts a real shell with a background child that writes a sentinel after a delay.
It cancels the parent task, waits beyond that delay, and checks that the child did
not write the sentinel. No installed toolchain, SDK, or Swiftly changes were needed.

The preceding Swift 6.3.3 and eight build/export acceptance checks are recorded in
[`SwiftBuild-Resource-Output.md`](SwiftBuild-Resource-Output.md).

## Build and export commands

The fixture was copied from the repository so that build state remained outside
the checkout. Its main executable calls `resourceMessage()` from
`ResourceDependency`, then reads `root-message.txt` through its own `Bundle.module`.
This tests both dependency and executable bundle lookup at runtime.

The following commands ran from the library checkout. The temporary directory
was new for this check. All required Swift toolchains and Static Linux SDKs were
already installed. The harness rejects an assessment requiring installation.

```sh
mkdir -p /tmp/triple-0.7.0-linux-proof
cp -R Tests/TripleTests/Fixtures/CrossCompilationPackage /tmp/triple-0.7.0-linux-proof/package
swift run --package-path /tmp/triple-0.7.0-linux-proof/harness Proof > /tmp/triple-0.7.0-linux-proof/export-builds.log 2>&1
```

The temporary harness manifest was:

```swift
// swift-tools-version: 6.3
import PackageDescription
let package = Package(
    name: "TripleLinuxResourceProof",
    platforms: [.macOS(.v13)],
    dependencies: [.package(path: "/Users/berken/Development/Swift/Triple/Triple")],
    targets: [.executableTarget(name: "Proof", dependencies: [.product(name: "Triple", package: "Triple")])]
)
```

Its `Sources/Proof/main.swift` was:

```swift
import Foundation
import Triple

@main
struct Proof {
    static func main() async throws {
        let root = URL(filePath: "/tmp/triple-0.7.0-linux-proof")
        let package = root.appending(path: "package")
        let kit = Triple()
        for version in [SwiftVersion(major: 6, minor: 3, patch: 3), SwiftVersion(major: 6, minor: 4, patch: 0)] {
            for architecture in [LinuxArchitecture.x86_64, .arm64] {
                let name = "swift-\(version)-\(architecture)"
                let assessment = try await kit.assess(package, for: .linux(architecture), toolchain: .exact(version))
                guard !assessment.requiresInstallation else {
                    throw NSError(domain: "Proof", code: 1, userInfo: [NSLocalizedDescriptionKey: "Required components are missing for \(name)."])
                }
                let environment = try await kit.prepare(assessment)
                let configuration = try await kit.configurePackage(using: environment, scratchStorage: .directory(root.appending(path: "configuration-\(name)")))
                let product = try configuration.products.select("CrossCompilationFixture")
                let scratch = root.appending(path: "scratch-\(name)")
                let export = root.appending(path: name)
                let result = try await kit.build(BuildRequest(product, configuration: .release, scratchStorage: .directory(scratch), output: .export(to: export, cleanup: .reset), strip: true), using: configuration.environment, dependencies: .resolveIfNeeded)
                guard !FileManager.default.fileExists(atPath: scratch.path()) else {
                    throw NSError(domain: "Proof", code: 2, userInfo: [NSLocalizedDescriptionKey: "Scratch directory still exists for \(name)."])
                }
                print("\(name): exported \(result.executable.path()); scratch removed; bundles=\(result.resourceBundles.map(\.lastPathComponent))")
            }
        }
    }
}
```

The export command exited 0. Triple used `.export(cleanup: .reset)` and the
harness checked that each scratch directory no longer existed before transfer:

```text
swift-6.3.3-x86_64: exported /tmp/triple-0.7.0-linux-proof/swift-6.3.3-x86_64/CrossCompilationFixture; scratch removed; bundles=["CrossCompilationFixture_CrossCompilationFixture.resources", "ResourceDependency_ResourceDependency.resources"]
swift-6.3.3-arm64: exported /tmp/triple-0.7.0-linux-proof/swift-6.3.3-arm64/CrossCompilationFixture; scratch removed; bundles=["CrossCompilationFixture_CrossCompilationFixture.resources", "ResourceDependency_ResourceDependency.resources"]
swift-6.4.0-x86_64: exported /tmp/triple-0.7.0-linux-proof/swift-6.4.0-x86_64/CrossCompilationFixture; scratch removed; bundles=["CrossCompilationFixture_CrossCompilationFixture.bundle", "ResourceDependency_ResourceDependency.bundle"]
swift-6.4.0-arm64: exported /tmp/triple-0.7.0-linux-proof/swift-6.4.0-arm64/CrossCompilationFixture; scratch removed; bundles=["CrossCompilationFixture_CrossCompilationFixture.bundle", "ResourceDependency_ResourceDependency.bundle"]
```

## Linux commands and output

No QEMU binary or ARM binfmt handler was installed on the host. Ubuntu's existing
APT metadata identified `qemu-user-static` version `1:8.2.2+ds-0ubuntu1.18`.
The downloaded package matched the metadata's SHA-256:

```text
5bb397f66063efa349f6fd5cb3b68cd96f29edd0994e4ba5115cf0859a716bf0
```

Only extraction into a temporary directory was performed. No package installation,
APT update, binfmt registration, or hosted-site change was needed. The emulator
reported `qemu-aarch64 version 8.2.2 (Debian 1:8.2.2+ds-0ubuntu1.18)`.

The remote preparation commands were:

```sh
proof_dir=$(mktemp -d /tmp/triple-0.7.0-linux.XXXXXX)
cd "$proof_dir"
curl --fail --location --silent --show-error https://archive.ubuntu.com/ubuntu/pool/universe/q/qemu/qemu-user-static_8.2.2+ds-0ubuntu1.18_amd64.deb --output qemu-user-static.deb
printf '%s\n' '5bb397f66063efa349f6fd5cb3b68cd96f29edd0994e4ba5115cf0859a716bf0  qemu-user-static.deb' | sha256sum --check
dpkg-deb --extract qemu-user-static.deb qemu
qemu/usr/bin/qemu-aarch64-static --version
```

The directory returned by `mktemp` for this run was
`/tmp/triple-0.7.0-linux.0ENenP`. Only the four exported directories were archived
and transferred. The local and remote archive SHA-256 values matched:

```text
ac52057079ace9a1ab6696515f14ddc911edcda3443b3bbb7773fd519834228a
```

```sh
tar -czf /tmp/triple-0.7.0-linux-proof/exports.tar.gz -C /tmp/triple-0.7.0-linux-proof swift-6.3.3-x86_64 swift-6.3.3-arm64 swift-6.4.0-x86_64 swift-6.4.0-arm64
shasum -a 256 /tmp/triple-0.7.0-linux-proof/exports.tar.gz
scp -q /tmp/triple-0.7.0-linux-proof/exports.tar.gz root@mottzi.codes:/tmp/triple-0.7.0-linux.0ENenP/exports.tar.gz
scp -q /tmp/triple-0.7.0-linux-proof/run-linux.sh root@mottzi.codes:/tmp/triple-0.7.0-linux.0ENenP/run-linux.sh
ssh -o BatchMode=yes root@mottzi.codes 'sh /tmp/triple-0.7.0-linux.0ENenP/run-linux.sh' > /tmp/triple-0.7.0-linux-proof/linux-execution.log 2>&1
```

The remote script was:

```sh
#!/bin/sh
set -eu
cd /tmp/triple-0.7.0-linux.0ENenP
sha256sum exports.tar.gz
tar -xzf exports.tar.gz
ulimit -c 0
printf '%s\n' 'Triple cross-compilation fixture' 'Triple executable resource fixture' > expected.txt
for output in swift-6.3.3-x86_64 swift-6.3.3-arm64 swift-6.4.0-x86_64 swift-6.4.0-arm64; do
  printf '%s\n' "$output"
  readelf -h "$output/CrossCompilationFixture" | awk '/Class:|Machine:/'
  if readelf -l "$output/CrossCompilationFixture" | grep -q INTERP; then
    printf '%s\n' 'Unexpected dynamic interpreter' >&2
    exit 1
  fi
  if readelf -d "$output/CrossCompilationFixture" | grep -q NEEDED; then
    printf '%s\n' 'Unexpected dynamic library' >&2
    exit 1
  fi
  if [ "${output##*-}" = arm64 ]; then
    qemu/usr/bin/qemu-aarch64-static "$output/CrossCompilationFixture" > "$output.stdout" 2> "$output.stderr"
    printf '%s\n' 'execution=ARM64 Linux user-mode emulation on x86_64 Ubuntu'
  else
    "./$output/CrossCompilationFixture" > "$output.stdout" 2> "$output.stderr"
    printf '%s\n' 'execution=native x86_64 Ubuntu'
  fi
  cmp expected.txt "$output.stdout"
  test ! -s "$output.stderr"
  cat "$output.stdout"
  printf '%s\n' 'exit=0; exact output matched; stderr empty; no INTERP or NEEDED'
done
```

The SSH command exited 0. The output below omits macOS extended-attribute tar
warnings, which occurred during extraction and did not affect the program output:

```text
ac52057079ace9a1ab6696515f14ddc911edcda3443b3bbb7773fd519834228a  exports.tar.gz
swift-6.3.3-x86_64
  Class:                             ELF64
  Machine:                           Advanced Micro Devices X86-64
execution=native x86_64 Ubuntu
Triple cross-compilation fixture
Triple executable resource fixture
exit=0; exact output matched; stderr empty; no INTERP or NEEDED
swift-6.3.3-arm64
  Class:                             ELF64
  Machine:                           AArch64
execution=ARM64 Linux user-mode emulation on x86_64 Ubuntu
Triple cross-compilation fixture
Triple executable resource fixture
exit=0; exact output matched; stderr empty; no INTERP or NEEDED
swift-6.4.0-x86_64
  Class:                             ELF64
  Machine:                           Advanced Micro Devices X86-64
execution=native x86_64 Ubuntu
Triple cross-compilation fixture
Triple executable resource fixture
exit=0; exact output matched; stderr empty; no INTERP or NEEDED
swift-6.4.0-arm64
  Class:                             ELF64
  Machine:                           AArch64
execution=ARM64 Linux user-mode emulation on x86_64 Ubuntu
Triple cross-compilation fixture
Triple executable resource fixture
exit=0; exact output matched; stderr empty; no INTERP or NEEDED
```

The exported executable SHA-256 values were:

| Export | SHA-256 |
| --- | --- |
| Swift 6.3.3 x86_64 | `e22643a56bbc428be4b7d216ffb206bd33663db36de9e4c0ff301448dd18c9d8` |
| Swift 6.3.3 aarch64 | `5542b4c14c29a0c48e55d3589efe0af7381984d52a46dcacde8a82b9afbdafec` |
| Swift 6.4.0 x86_64 | `d1d73799e68a293b1048327354e807a96b15bb60a01a2c66125e0484c733ecd9` |
| Swift 6.4.0 aarch64 | `ee908324f62a3d80d6ee4c050086de8a953352820c32c869ad5ffb311b08eb70` |

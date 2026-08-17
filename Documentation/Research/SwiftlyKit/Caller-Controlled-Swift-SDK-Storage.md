# Caller-Controlled Swift SDK Storage in SwiftlyKit

**Reference date:** 17 August 2026

**Upstream baseline:** SwiftPM 6.3.3 at
[`5f6969f`](https://github.com/swiftlang/swift-package-manager/commit/5f6969f5b083b4415632114d4897c6f820761a7f),
SwiftPM `main` at
[`3e22779`](https://github.com/swiftlang/swift-package-manager/commit/3e2277952497247c2064745aefeef930fe199cff),
Swiftly `main` at
[`5ef4546`](https://github.com/swiftlang/swiftly/commit/5ef4546fecd36b803e3c313c830e10324466f0a1),
and accepted SE-0387

**Status:** Recommendation to pursue before publishing the current custom
Swiftly-storage work

## Question

Should SwiftlyKit let a caller place installed Static Linux SDKs in a dedicated
directory, rather than always using SwiftPM's standard per-user SDK registry?
Can it do so without reimplementing SwiftPM, weakening security, becoming
stateful, or adding a disproportionate public interface?

## Recommendation

**Yes. Pursue this capability, but implement it only through SwiftPM's existing
`--swift-sdks-path` mechanism.** The earlier premise that SwiftPM cannot install
or remove an SDK in a caller-selected directory is incorrect.

`swift sdk install` and `swift sdk remove` hide their common location options
from generated help, but both commands parse `--swift-sdks-path`. SwiftPM 6.3.3
passes the parsed directory into the same `SwiftSDKBundleStore` used for normal
installation and removal.
[SwiftPM 6.3.3 install command](https://github.com/swiftlang/swift-package-manager/blob/5f6969f5b083b4415632114d4897c6f820761a7f/Sources/SwiftSDKCommand/InstallSwiftSDK.swift#L23-L87),
[common SDK-command directory resolution](https://github.com/swiftlang/swift-package-manager/blob/5f6969f5b083b4415632114d4897c6f820761a7f/Sources/SwiftSDKCommand/SwiftSDKSubcommand.swift#L21-L75),
[remove command](https://github.com/swiftlang/swift-package-manager/blob/5f6969f5b083b4415632114d4897c6f820761a7f/Sources/SwiftSDKCommand/RemoveSwiftSDK.swift#L19-L113)

This is not merely an accidental parser side effect. SwiftPM's own 6.3.3
command test installs, lists, rejects a duplicate, removes, and lists again
against one explicit `--swift-sdks-path` directory.
[SwiftPM 6.3.3 end-to-end command test](https://github.com/swiftlang/swift-package-manager/blob/5f6969f5b083b4415632114d4897c6f820761a7f/Tests/CommandsTests/SwiftSDKCommandTests.swift#L75-L158)
The same explicit-root install/list/remove test is present in the Swift 6.0,
6.1, and 6.2 release sources, so every stable Swift generation SwiftlyKit can
currently select has first-party test coverage for this behavior.
[SwiftPM 6.0 install source](https://github.com/swiftlang/swift-package-manager/blob/5bd155f053b23664a8bb586f625aa9f8fa83ed86/Sources/SwiftSDKCommand/InstallSwiftSDK.swift#L23-L67),
[SwiftPM 6.0 command test](https://github.com/swiftlang/swift-package-manager/blob/5bd155f053b23664a8bb586f625aa9f8fa83ed86/Tests/CommandsTests/SwiftSDKCommandTests.swift#L40-L122),
[SwiftPM 6.1 install source](https://github.com/swiftlang/swift-package-manager/blob/1fc90e29029bfeafe3550ccf08f74a86a11baa23/Sources/SwiftSDKCommand/InstallSwiftSDK.swift#L23-L67),
[SwiftPM 6.1 command test](https://github.com/swiftlang/swift-package-manager/blob/1fc90e29029bfeafe3550ccf08f74a86a11baa23/Tests/CommandsTests/SwiftSDKCommandTests.swift#L42-L124),
[SwiftPM 6.2 install source](https://github.com/swiftlang/swift-package-manager/blob/3cf1cb66ebde00dab737dcebad96218e2017530d/Sources/SwiftSDKCommand/InstallSwiftSDK.swift#L23-L87),
[SwiftPM 6.2 command test](https://github.com/swiftlang/swift-package-manager/blob/3cf1cb66ebde00dab737dcebad96218e2017530d/Tests/CommandsTests/SwiftSDKCommandTests.swift#L50-L129)

The minimal public design is not another independent SDK-path parameter. Before
the current unreleased `SwiftlyStorage` interface becomes precedent, generalize
it into one installation namespace—provisionally `EnvironmentStorage`:

```swift
public enum EnvironmentStorage: Sendable, Hashable {
    case standard
    case directory(URL)
}

public init(environmentStorage: EnvironmentStorage = .standard)
```

`.standard` should preserve today's normal Swiftly and SwiftPM locations.
`.directory(root)` should derive Swiftly home and binaries, toolchains, and a
`root/swift-sdks` registry. The selection must be captured by assessment,
carried by the prepared environment, and serialized into removal plans, exactly
as the current work does for `SwiftlyStorage`.

This recommendation adds one missing derived directory to one existing
unreleased choice. It does not add a second public storage value or another
parameter to the ordinary workflow. Users who do not choose custom storage see
no API or behavior change beyond the more accurate type and initializer label.

## What SwiftPM actually supports

### One directory is already the store abstraction

SwiftPM's `LocationOptions` defines `--swift-sdks-path` as the path containing
installed Swift SDKs. Build and list expose it in help. Install and remove embed
the same option group with hidden visibility, which hides the option from those
help pages without preventing parsing.
[SwiftPM 6.3.3 location option](https://github.com/swiftlang/swift-package-manager/blob/5f6969f5b083b4415632114d4897c6f820761a7f/Sources/CoreCommands/Options.swift#L121-L130),
[hidden install option group](https://github.com/swiftlang/swift-package-manager/blob/5f6969f5b083b4415632114d4897c6f820761a7f/Sources/SwiftSDKCommand/InstallSwiftSDK.swift#L23-L39),
[hidden remove option group](https://github.com/swiftlang/swift-package-manager/blob/5f6969f5b083b4415632114d4897c6f820761a7f/Sources/SwiftSDKCommand/RemoveSwiftSDK.swift#L19-L31)

When an explicit directory is supplied, SwiftPM creates it if necessary and
returns it directly. Without one, SwiftPM uses its platform-specific per-user
location. On macOS that is normally
`~/Library/org.swift.swiftpm/swift-sdks`; SwiftPM also maintains a legacy
`~/.swiftpm/swift-sdks` symlink to it.
[SwiftPM 6.3.3 SDK-directory implementation](https://github.com/swiftlang/swift-package-manager/blob/5f6969f5b083b4415632114d4897c6f820761a7f/Sources/Basics/FileSystem/FileSystem%2BExtensions.swift#L486-L542)

Build uses the same parsed directory when constructing `SwiftSDKBundleStore`
and selecting a target SDK. An explicit root therefore controls both physical
installation and build-time discovery; it is not only an alternate search hint.
[SwiftPM 6.3.3 command state](https://github.com/swiftlang/swift-package-manager/blob/5f6969f5b083b4415632114d4897c6f820761a7f/Sources/CoreCommands/SwiftCommandState.swift#L251-L252),
[explicit-directory binding](https://github.com/swiftlang/swift-package-manager/blob/5f6969f5b083b4415632114d4897c6f820761a7f/Sources/CoreCommands/SwiftCommandState.swift#L419-L421),
[SDK selection from that store](https://github.com/swiftlang/swift-package-manager/blob/5f6969f5b083b4415632114d4897c6f820761a7f/Sources/CoreCommands/SwiftCommandState.swift#L1027-L1036)

### Local verification

The installed Apple Swift 6.3.3 toolchain was checked on the reference date.
Although `swift sdk install --help` and `swift sdk remove --help` omitted
`--swift-sdks-path`, both commands accepted it. Using SwiftPM's official
`Fixtures/SwiftSDKs/test-sdk.artifactbundle.zip`, this sequence installed only
under a fresh temporary root, listed `test-artifact` from that root, removed it,
and left the root empty:

```text
swift sdk install --swift-sdks-path <temporary>/sdks <fixture>
swift sdk list --swift-sdks-path <temporary>/sdks
swift sdk remove --swift-sdks-path <temporary>/sdks test-artifact
```

This local check agrees with the pinned release source and its end-to-end test;
the recommendation does not depend on unreleased `main` behavior.

### Installation security and validation are preserved

For a remote URL, SwiftPM requires a checksum, accepts only a successful HTTP
response, computes the archive checksum, and rejects a mismatch before using
the archive. It unpacks into a temporary directory, validates the artifact
bundle and its Swift SDK metadata, rejects duplicate bundle names and artifact
identifiers, and only then copies the bundle into the selected store.
[SwiftPM 6.3.3 download and checksum path](https://github.com/swiftlang/swift-package-manager/blob/5f6969f5b083b4415632114d4897c6f820761a7f/Sources/PackageModel/SwiftSDKs/SwiftSDKBundleStore.swift#L164-L240),
[unpack and duplicate-name validation](https://github.com/swiftlang/swift-package-manager/blob/5f6969f5b083b4415632114d4897c6f820761a7f/Sources/PackageModel/SwiftSDKs/SwiftSDKBundleStore.swift#L243-L280),
[bundle validation and installation](https://github.com/swiftlang/swift-package-manager/blob/5f6969f5b083b4415632114d4897c6f820761a7f/Sources/PackageModel/SwiftSDKs/SwiftSDKBundleStore.swift#L282-L355)

SE-0387 defines the checksum as the publisher-supplied integrity mechanism and
requires bundle-relative paths and symlinks not to escape the bundle.
[SE-0387 installation and checksum design](https://github.com/swiftlang/swift-evolution/blob/4cdd9ffdc9f312378d230250b5e8f83aa7e2e361/proposals/0387-cross-compilation-destinations.md#L384-L406),
[SE-0387 path-containment requirement](https://github.com/swiftlang/swift-evolution/blob/4cdd9ffdc9f312378d230250b5e8f83aa7e2e361/proposals/0387-cross-compilation-destinations.md#L309-L355)

SwiftlyKit would still supply the official release URL and published checksum.
Changing only the store argument therefore preserves the current download,
checksum, archive, metadata, quarantine, and duplicate checks. Reimplementing
installation would not.

## Why the capability is valuable

The installed SDK is a durable and potentially large prerequisite, not a
temporary build product. With a custom Swiftly root but the standard SDK store,
an embedding application cannot truthfully say that its cross-compilation
environment is contained in its chosen directory. It still mutates the user's
global SwiftPM SDK registry and shares SDK identity and removal with unrelated
SwiftPM use.

A dedicated installation namespace gives consumers concrete benefits:

- an application or build daemon can keep the Swiftly executable, toolchains,
  and matching SDKs under one caller-owned root;
- CI can restore, cache, or discard that complete environment as one unit;
- different applications or test installations do not collide through the
  user's SDK registry;
- assessment, preparation, build validation, and removal can all observe the
  same explicit namespace; and
- standard users keep sharing the normal per-user installation and pay no
  configuration cost.

These benefits are generic to an embedded cross-compilation library. They do
not depend on Triple.

## Public-interface shape

### Prefer one environment-installation namespace

SwiftlyKit always prepares a compatible pair: one Swift toolchain and its
matching Static Linux SDK. Swiftly itself is the mechanism used to install and
select the toolchain. These are all durable prerequisites whose availability is
assessed before a build and whose installation may be recorded for later
removal. Grouping their storage choice matches SwiftlyKit's domain boundary,
even though Swiftly owns two mechanisms and SwiftPM owns the SDK mechanism.

A custom root should have one predictable shape:

```text
root/
├── bin/
├── toolchains/
├── swift-sdks/
└── <Swiftly home state>
```

The exact internal layout remains SwiftlyKit's concern. A caller chooses only
between official defaults and one dedicated root.

Keeping the public name `SwiftlyStorage` while silently extending it to SDKs is
misleading: Static Linux SDKs are installed and interpreted by SwiftPM, not by
Swiftly. `EnvironmentStorage` is more honest and keeps the initializer at one
advanced option. The current worktree has no released compatibility constraint,
so correcting the name now is cheaper than documenting the semantic mismatch.

### Keep SwiftPM shared and scratch storage separate

The storage categories have different lifetimes and ownership:

| Choice | Contents | Lifetime and cleanup |
|---|---|---|
| `EnvironmentStorage` | Swiftly state and executable, installed toolchains, installed Static Linux SDKs | Durable prerequisites; exact toolchain/SDK removal is caller-requested through a removal plan; Swiftly/root removal remains caller-owned |
| `SwiftPMSharedStorage` | dependency cache, mirrors/registry configuration, credentials and trust state | Potentially shared across many packages and environments; never removed automatically by SwiftlyKit |
| `SwiftPMScratchStorage` | package workspace, checkouts, intermediates, and build outputs | Per-package or per-build workflow storage; eligible for SwiftPM cleanup operations |

Putting SDKs into `SwiftPMSharedStorage` merely because SwiftPM implements them
would obscure these lifecycle differences. SDKs are selected, installed, and
removed as part of the prepared compiler environment; caches and trust state
are workflow infrastructure. Scratch data is disposable build state.

### Do not add an independent `SwiftSDKStorage` yet

Independent toolchain and SDK roots have legitimate advanced uses. A CI system
might want private toolchains with a shared SDK cache, or vice versa. That
flexibility is not free: it introduces another public type or initializer
parameter, more overlap combinations, more removal-plan state, and a custom
mode in which the supposedly dedicated environment root is intentionally
incomplete.

No current SwiftlyKit workflow requires that separation. Most users who need a
custom location need ownership and isolation of the complete prepared
environment. The smaller, more intuitive contract is therefore to couple the
derived roots now. A separately configurable SDK root can be added later if
real consumers demonstrate independent lifecycle or sharing requirements.

## Required command semantics

For `.standard`, SwiftlyKit should omit `--swift-sdks-path` where it does today
and preserve SwiftPM's default-location behavior. For `.directory(root)`, it
must apply `--swift-sdks-path root/swift-sdks` consistently to:

1. SDK inspection during assessment and preparation;
2. SDK installation;
3. SDK post-install verification;
4. SDK inspection and removal from an `EnvironmentRemovalPlan`; and
5. any SwiftPM invocation that discovers the installed bundle.

Builds should retain SwiftlyKit's existing exact-selection directory containing
only the prepared SDK, rather than exposing every SDK in the installation root
to a build. That narrower build-time view and the physical installation root
solve different problems: one prevents ambiguous or stale selection; the other
controls storage ownership.

Assessment must preserve its read-only promise. SwiftPM creates an explicit SDK
directory when it does not exist.
[SwiftPM explicit-directory creation](https://github.com/swiftlang/swift-package-manager/blob/5f6969f5b083b4415632114d4897c6f820761a7f/Sources/Basics/FileSystem/FileSystem%2BExtensions.swift#L508-L518)
Therefore assessment should treat a missing custom `swift-sdks` directory as an
empty registry without invoking `swift sdk list`; preparation may create it
after the caller authorizes installation. An existing directory can be listed
without that creation side effect.

If the selected toolchain rejects the option, custom-mode operations must fail
closed with a clear incompatibility error. They must never retry against the
standard registry, because that would silently defeat the caller's ownership
choice. A separate public capability-probe API is unnecessary: the first
explicit-root inspection or preparation command is already the authoritative
probe, and release-level coverage makes rejection unlikely for supported Swift
versions.

## Statelessness and removal ownership

Caller-controlled SDK storage does not require SwiftlyKit to retain a registry,
lease, or ownership database. `EnvironmentStorage` is immutable configuration.
Assessment captures it, `LocalBuildEnvironment` carries it, and a serializable
removal plan identifies the same namespace. SwiftlyKit continues to derive
live state from Swiftly and SwiftPM on each operation.

The caller still decides whether and when to remove anything. SwiftlyKit should
not delete a custom root automatically: it may be cached, shared by multiple
packages, or contain resources installed outside the current invocation. An
exact plan should pass the same `--swift-sdks-path` to `swift sdk remove`, then
verify absence in that same store before considering SDK removal complete.

This keeps the existing write-ahead model intact. Before an SDK installation,
the recorder receives a plan containing the exact SDK identity and the selected
environment namespace. If installation completes, fails normally, or the
caller later restarts, that value still tells SwiftlyKit where to inspect and
remove the SDK. No automatic rollback or internal persistence is introduced.

### Existing crash-safety limit

SwiftPM validates and unpacks an archive in temporary storage, but its final
publication is a filesystem `copy`, not an atomic rename.
[SwiftPM 6.3.3 final installation copy](https://github.com/swiftlang/swift-package-manager/blob/5f6969f5b083b4415632114d4897c6f820761a7f/Sources/PackageModel/SwiftSDKs/SwiftSDKBundleStore.swift#L315-L336)
Hard termination during that copy can therefore leave a partial bundle
directory. `swift sdk remove <artifact-id>` finds IDs by parsing valid bundles;
an invalid partial bundle may not be discoverable by that identifier, although
removal by exact bundle-directory name deletes the directory before parsing
bundle metadata.
[SwiftPM 6.3.3 removal behavior](https://github.com/swiftlang/swift-package-manager/blob/5f6969f5b083b4415632114d4897c6f820761a7f/Sources/SwiftSDKCommand/RemoveSwiftSDK.swift#L41-L63)

This is an existing limit of both the standard registry and the proposed custom
registry, not a cost introduced by caller-controlled storage. It does mean that
SwiftlyKit should not claim fully transactional SDK installation. During
implementation, the existing removal-plan tests should be extended to a custom
root, and exact official Static Linux bundle naming should be evaluated as an
internal recovery aid for invalid partial copies. That investigation should not
produce a broader public storage interface unless the current plan cannot
represent a safe recovery target.

## Rejected implementation alternatives

### Do nothing

Doing nothing preserves the smallest code change, and the existing isolated
build-selection directory prevents SwiftPM from choosing unrelated SDKs during
a build. It does not provide storage isolation, caller ownership, disposable CI
environments, or honest containment for a custom Swiftly root. Now that the
first-party mechanism is known, the remaining inconsistency is not justified by
implementation cost.

### Build-time selection only

Passing a narrow `--swift-sdks-path` only to `swift build` is worth retaining
for exact SDK selection, but it cannot redirect the earlier install or later
remove mutation. It solves ambiguity, not installation ownership.

### Isolate `HOME` or `CFFIXED_USER_HOME`

SwiftPM does not define either variable as its SDK-store interface. Its default
implementation asks Foundation for the user-domain Library directory and uses
`XDG_CONFIG_HOME` only for the fallback `.swiftpm` directory.
[SwiftPM user-directory selection](https://github.com/swiftlang/swift-package-manager/blob/5f6969f5b083b4415632114d4897c6f820761a7f/Sources/Basics/FileSystem/FileSystem%2BExtensions.swift#L214-L234),
[SwiftPM SDK default](https://github.com/swiftlang/swift-package-manager/blob/5f6969f5b083b4415632114d4897c6f820761a7f/Sources/Basics/FileSystem/FileSystem%2BExtensions.swift#L486-L505)

On the reference macOS host, changing `HOME` alone did not redirect the SDK
registry, while `CFFIXED_USER_HOME` redirected Foundation's user Library and
caused SwiftPM to create both Library and `.swiftpm` state below the replacement
home. `CFFIXED_USER_HOME` is not documented by SwiftPM as an SDK option and
changes the process-wide Foundation notion of user storage. It is consequently
a much broader and less stable contract than the dedicated path flag.

`SWIFTPM_CUSTOM_LIBS_DIR` is also unrelated. SwiftPM reads it only while deriving
the location of SwiftPM's own PackageDescription and plugin support libraries;
it does not select the Swift SDK bundle store.
[SwiftPM custom-libraries implementation](https://github.com/swiftlang/swift-package-manager/blob/5f6969f5b083b4415632114d4897c6f820761a7f/Sources/PackageModel/UserToolchain.swift#L952-L982)

Swiftly's own supported storage variables likewise cover Swiftly home, binaries,
and toolchains, not SwiftPM's SDK registry.
[Swiftly custom-install documentation](https://github.com/swiftlang/swiftly/blob/5ef4546fecd36b803e3c313c830e10324466f0a1/Documentation/SwiftlyDocs.docc/automated-install.md#L72-L94),
[Swiftly macOS path implementation](https://github.com/swiftlang/swiftly/blob/5ef4546fecd36b803e3c313c830e10324466f0a1/Sources/MacOSPlatform/MacOS.swift#L21-L42),
[Swiftly home implementation](https://github.com/swiftlang/swiftly/blob/5ef4546fecd36b803e3c313c830e10324466f0a1/Sources/SwiftlyCore/Platform.swift#L155-L177)

### Download and extract the archive directly

This would make SwiftlyKit own SwiftPM's archive formats, checksum behavior,
HTTP response policy, temporary extraction, quarantine handling, artifact
metadata schema, supported-host validation, path containment, duplicate
identity rules, and future bundle evolution. Those responsibilities are
already implemented behind `swift sdk install`, including when the store is
explicit. Reimplementation would increase code, security responsibility, and
compatibility risk without adding user value.

### Install globally, then move or symlink

This mutates the standard registry before isolation exists, creates a failure
window between install and relocation, can race unrelated SwiftPM processes,
and requires SwiftlyKit to infer bundle layout and repair both registries.
SwiftPM itself accepts the final directory at installation time, so a
post-install move has no compensating benefit.

### Make SwiftlyKit own a private SwiftPM library implementation

`SwiftSDKBundleStore` exists as SwiftPM source, but SwiftlyKit does not depend on
libSwiftPM and should not adopt its internal module graph merely to select a
directory already accepted by the CLI. Subprocess delegation keeps SwiftlyKit
small and uses the implementation paired with the selected toolchain.

## Cost and risk assessment

| Concern | Assessment |
|---|---|
| Public API size | Low if `SwiftlyStorage` is generalized before release; no additional option for ordinary users |
| Internal implementation | Moderate and mechanical: carry one derived URL and apply it to every SDK lifecycle command and locator |
| Security | Better than custom extraction; official SwiftPM checksum and bundle validation remain in force |
| Statelessness | Preserved; the path is immutable input and removal remains explicitly caller-requested |
| Compatibility | Low-to-moderate risk because install/remove hide the option, reduced substantially by first-party release tests from Swift 6.0 through 6.3.3 |
| Failure isolation | Improved for applications and CI; custom environments no longer share the user's SDK registry |
| Cleanup complexity | No new automatic cleanup; plans must carry and consistently use the namespace |
| Transactionality | Unchanged; SwiftPM's final copy is not atomic and must not be described as crash-proof |

The hidden help visibility is the only material upstream-stability concern. It
does not outweigh the benefit here because the option is a named, shared
`LocationOptions` member; build exposes it publicly; four Swift release lines
exercise install and remove with it in first-party command tests; and SwiftlyKit
already exists to hide selected-toolchain CLI mechanics. SwiftlyKit should
still fail closed and cover the behavior with an integration fixture so an
upstream regression is detected immediately.

## Acceptance criteria for a later implementation

1. Keep a single defaulted public storage choice; do not add a separate SDK
   parameter.
2. Rename/generalize the unreleased `SwiftlyStorage` concept so its name honestly
   includes the SDK namespace.
3. Derive and safety-check `swift-sdks` under a custom root, including symlink
   escape and overlap checks already applied to the other derived paths.
4. Preserve read-only assessment when the derived SDK directory does not yet
   exist.
5. Pass the explicit root to every custom-mode SDK list, install, verification,
   and remove command; never fall back to the standard registry.
6. Keep standard mode behavior unchanged.
7. Keep the exact one-SDK build selection directory.
8. Carry the namespace through both staged and fast-track workflows and through
   persisted removal plans.
9. Verify remote checksum rejection, duplicate handling, custom-root discovery,
   custom-root removal, cancellation, recorder failure, and standard/custom
   separation in tests.
10. Document the remaining non-atomic final-copy limitation accurately; do not
    promise transactional installation.

## Final assessment

Caller-controlled Swift SDK storage is worth adding. It completes the meaning
of a caller-controlled cross-compilation environment, benefits CI, applications,
and build services, and fixes an otherwise surprising split between toolchain
and SDK ownership.

Most importantly, it does **not** require a complicated custom installer.
SwiftPM already owns the operation. SwiftlyKit needs only to model the namespace
cohesively, pass the first-party path consistently, preserve its existing
write-ahead removal ownership, and fail closed if the selected toolchain cannot
honor the explicit store.

# Cold-cache host SDK recovery

Reference date: 10 October 2026.

Cold dependency inspection could skip installed SDK recovery even when the
compiler had crashed. Deployer at tracked source commit `566936b` exposed the
failure with exact Swift 6.3.3 and macOS SDK 27.0. Its root manifest succeeded,
but the `swift-crypto` dependency manifest crashed with signal 11. SDK 26.5 could
evaluate the same graph successfully.

The raw cold graph output had 30,414 characters, with the first compiler-failure
marker at index 13,318. `boundedDiagnostic` retained 12,000 leading characters
and 4,000 trailing characters. Both signal markers fell outside those regions.
Recovery classified this shortened diagnostic and therefore treated the crash
as an ordinary dependency failure.

Command-failure classification now uses captured stdout and stderr. The existing
four compiler/SDK markers are unchanged. The internal error retains only the
bounded caller-facing diagnostic. Root inspection, graph inspection, and explicit
dependency resolution use the same classifier. Ordinary errors retain their
existing public error types and do not trigger SDK retries.

## Regression checks

`swift test --filter 'PackageInspectionTests/long'` failed before the fix in both
graph-inspection and dependency-resolution cases. It passed after the fix. The
fixtures put the signal marker after a long fetch log and before a long compiler
backtrace, and assert that the bounded diagnostic does not contain the marker.
Successful retry binds SDK 26.5 and keeps exact Swift 6.3.3. Long ordinary errors
remain bounded and stop without retry in both operations. Recovery exhaustion
also tests that a long compiler failure returns a bounded public diagnostic.

## Real cold dependency check

The Deployer source and `Package.resolved` were copied into
`/tmp/triple-0.7.0-linux-proof/cold-deployer`, excluding `.build`, `.swiftpm`, and
`.git`. A temporary SwiftPM executable depended on the local Triple checkout.
It selected exact Swift 6.3.3 and rejected any assessment requiring installation.
`prepare` received new, empty `SwiftPMSharedStorage` cache, configuration, and
security directories. Root configuration and graph inspection also used separate
new scratch directories. No installed toolchain, SDK, or Swiftly changes occurred.

The harness required root configuration to retain SDK 27.0, then called
`inspectPackage(using:scratchStorage:dependencies:onEvent:)` with
`.resolveIfNeeded`. It required successful graph inspection to return SDK 26.5,
Swift 6.3.3, and an executable product. The command was:

```sh
swift run --package-path /tmp/triple-0.7.0-linux-proof/cold-harness ColdProof > /tmp/triple-0.7.0-linux-proof/cold-recovery-deployer.log 2>&1
```

It exited 0. The progress output was:

```text
Inspecting the root package manifest with Swift 6.3.3 and macOS SDK 27.0.
Inspecting package dependencies with Swift 6.3.3 and macOS SDK 27.0.
Retrying inspection of package dependencies with installed macOS SDK 27.0; keeping Swift 6.3.3.
Retrying inspection of package dependencies with installed macOS SDK 27.0; keeping Swift 6.3.3.
Retrying inspection of package dependencies with installed macOS SDK 26.5; keeping Swift 6.3.3.
Successfully inspected package dependencies. Using macOS SDK 26.5 with Swift 6.3.3.
cold dependency recovery passed: Swift 6.3.3, SDK 26.5, products ["deployer"]
```

The SDK 27.0 retries use other installed SDK directories with the same reported
version. Their failure does not change the exact compiler selection.

## Full suite

```sh
TRIPLE_RUN_ACCEPTANCE=1 TRIPLE_TEST_HOST_CACHE=1 swift test > /tmp/triple-0.7.0-linux-proof/cold-recovery-full-suite-rerun.log 2>&1
```

The command exited 0 with no skipped tests:

```text
Test run with 354 tests in 46 suites passed after 42.998 seconds.
```

This includes real subprocess-group cancellation, live host-cache SDK recovery,
traits acceptance, eight cross-compilation build/export combinations, and
consecutive-build artifact identity. The final package-inspection check also
passed 13 tests after the bounded-exhaustion case was added.

The first full run, concurrent with the cold dependency workload, reported one
failure in the unchanged source-observer test for a nested root overriding an
excluded ancestor. Its complete eight-test suite passed alone. The full suite
then passed on rerun without changing the observer implementation or its tests.

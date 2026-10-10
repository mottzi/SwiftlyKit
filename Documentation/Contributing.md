# Contributing

Run checks from the repository root:

```sh
swift test
```

Enable real-system acceptance tests on a prepared host:

```sh
TRIPLE_RUN_ACCEPTANCE=1 swift test --filter AcceptanceTests
```

Acceptance tests do not install tools. Prepare the required Swiftly installation, official Swift toolchains, and matching Static Linux SDKs before running them. Check the test source for the exact versions under test. Set `TRIPLE_TEST_HOST_CACHE=1` to enable the real host manifest cache tests.

See [Architecture](Architecture.md) for the internal design and [release notes](Releases/0.7.0.md) for release validation references.

Triple retains the existing `SwiftlyKit` cache and coordination directories. This preserves cached metadata and locking with older clients. Temporary output names use `.triple`. The internal manifest cache context is owned by Triple; callers cannot supply either the old or new context environment key.

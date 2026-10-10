# Swift Build resource output in Triple

Reference date: 9 October 2026.

Status: implemented in Triple's build-output inspection and verified with both toolchains.

Upstream baselines are the `swift-6.4.0-RELEASE` tags, resolved to SwiftPM
[`18da3eb1e770679f6910890fbd52e95af53f67d2`](https://github.com/swiftlang/swift-package-manager/tree/18da3eb1e770679f6910890fbd52e95af53f67d2)
and Swift Build
[`807b9cd2dc7a447cafe9a6612df47f95313f2877`](https://github.com/swiftlang/swift-build/tree/807b9cd2dc7a447cafe9a6612df47f95313f2877).

## Finding

Triple can adopt the default build system. This is a focused compatibility change,
but deleting `--build-system native` alone breaks resource verification.

Swift Build supplies enough information to identify the selected executable's
resource bundles. Its generated `manifest.pif` describes linked targets and their
resource bundle names. Use active links from that file, then validate the named
bundles in the binary directory. Do not copy all bundles in the directory, and do
not traverse all build dependencies. These include host tools and unrelated
products.

This recommendation is an inference from the pinned source and the observed
fixture. PIF is the input project model, not a supported public deployment
manifest. Triple must reject unsupported or ambiguous metadata instead of
silently exporting the wrong resources. SwiftPM describes PIF as a static project
model reused across configurations and builds.
[PIF definition](https://github.com/swiftlang/swift-package-manager/blob/18da3eb1e770679f6910890fbd52e95af53f67d2/Sources/SwiftBuildSupport/PIF.swift#L22-L30)

## Why the existing verifier cannot work unchanged

Triple reads `<product>.product/Objects.LinkFileList`, finds
`resource_bundle_accessor.swift.o` entries, and reads each target's generated
Swift accessor. It requires both a relative bundle name and an absolute build
bundle path in that source. See `Sources/Triple/SwiftPM/Output/SwiftPMBuildOutput.swift`.

The native accessor supplies these two paths. Swift Build's accessor instead
declares `let bundleName = "Package_Module"` and appends `".bundle"` at runtime. It
checks bundle locations for apps, frameworks, and command-line tools. It does not
include the native absolute build-path fallback.
[Native accessor](https://github.com/swiftlang/swift-package-manager/blob/18da3eb1e770679f6910890fbd52e95af53f67d2/Sources/Build/BuildDescription/SwiftModuleBuildDescription.swift#L423-L444),
[Swift Build accessor](https://github.com/swiftlang/swift-build/blob/807b9cd2dc7a447cafe9a6612df47f95313f2877/Sources/SWBTaskConstruction/TaskProducers/BuildPhaseTaskProducers/SourcesTaskProducer.swift#L2021-L2086)

Swift Build places products in `dataPath/Products/<configuration><platform suffix>`
and intermediates in `dataPath/Intermediates.noindex`. The binary directory is
therefore not the parent of the target intermediate directories. Continue to
query SwiftPM for the binary directory instead of constructing this path.
[Product directory](https://github.com/swiftlang/swift-package-manager/blob/18da3eb1e770679f6910890fbd52e95af53f67d2/Sources/SwiftBuildSupport/SwiftBuildSystem.swift#L310-L325),
[Build arena](https://github.com/swiftlang/swift-package-manager/blob/18da3eb1e770679f6910890fbd52e95af53f67d2/Sources/SwiftBuildSupport/SwiftBuildSystem.swift#L1147-L1156)

Dependency objects can live in `.objlib` directories. Swift Build copies the
objects into those directories and writes an `args.resp` file. The linker receives
`@<object-library>/args.resp` separately. The executable's own `.LinkFileList` is
not a list of all dependency objects.
[Object library creation](https://github.com/swiftlang/swift-build/blob/807b9cd2dc7a447cafe9a6612df47f95313f2877/Sources/SWBTaskExecution/TaskActions/ObjectLibraryAssemblerTaskAction.swift#L35-L76),
[Object library linker argument](https://github.com/swiftlang/swift-build/blob/807b9cd2dc7a447cafe9a6612df47f95313f2877/Sources/SWBCore/SpecImplementations/Tools/LinkerTools.swift#L1700-L1738)

## Resource identification through PIF

SwiftPM writes `manifest.pif` before building. Its location is
`dataPath/../manifest.pif`, which was the scratch directory in the observed builds.
Pass the known scratch directory into verification. Do not infer it by walking
up from the binary directory.
[PIF write](https://github.com/swiftlang/swift-package-manager/blob/18da3eb1e770679f6910890fbd52e95af53f67d2/Sources/SwiftBuildSupport/SwiftBuildSystem.swift#L1418-L1420),
[PIF path](https://github.com/swiftlang/swift-package-manager/blob/18da3eb1e770679f6910890fbd52e95af53f67d2/Sources/SPMBuildCore/BuildParameters/BuildParameters.swift#L298-L301)

The source establishes these rules:

- `addDependency(..., linkProduct: true)` adds a target reference to the frameworks
  build phase. Build-only dependencies have no such reference. Plugin and macro
  dependencies are explicitly build-only for an executable.
  [Linked edge encoding](https://github.com/swiftlang/swift-build/blob/807b9cd2dc7a447cafe9a6612df47f95313f2877/Sources/SwiftBuild/ProjectModel/Targets.swift#L295-L304),
  [Host dependencies](https://github.com/swiftlang/swift-package-manager/blob/18da3eb1e770679f6910890fbd52e95af53f67d2/Sources/SwiftBuildSupport/PackagePIFProjectBuilder%2BProducts.swift#L441-L459)
- Standard targets store these references in `buildPhases`. Automatic library
  products use a top-level `frameworksBuildPhase`. Both forms must be read.
  [Target serialization](https://github.com/swiftlang/swift-build/blob/807b9cd2dc7a447cafe9a6612df47f95313f2877/Sources/SwiftBuild/ProjectModel/Targets.swift#L404-L462)
- Automatic library products impart links to their constituent module targets.
  The executable and product builders include transitive linkage dependencies.
  [Library module links](https://github.com/swiftlang/swift-package-manager/blob/18da3eb1e770679f6910890fbd52e95af53f67d2/Sources/SwiftBuildSupport/PackagePIFProjectBuilder%2BProducts.swift#L698-L719),
  [Transitive executable links](https://github.com/swiftlang/swift-package-manager/blob/18da3eb1e770679f6910890fbd52e95af53f67d2/Sources/SwiftBuildSupport/PackagePIFProjectBuilder%2BProducts.swift#L413-L528)
- Resource-owning module targets declare `PACKAGE_RESOURCE_BUNDLE_NAME` in build
  settings. SwiftPM creates a separate resource target with `productType = .bundle`,
  adds a build-only resource dependency, and sets `PACKAGE_RESOURCE_TARGET_KIND`
  to `resource`. The bundle name is `<package name>_<module name>`.
  [Module resource name](https://github.com/swiftlang/swift-package-manager/blob/18da3eb1e770679f6910890fbd52e95af53f67d2/Sources/SwiftBuildSupport/PackagePIFProjectBuilder%2BModules.swift#L718-L723),
  [Resource target](https://github.com/swiftlang/swift-package-manager/blob/18da3eb1e770679f6910890fbd52e95af53f67d2/Sources/SwiftBuildSupport/PackagePIFProjectBuilder.swift#L183-L238),
  [Naming](https://github.com/swiftlang/swift-package-manager/blob/18da3eb1e770679f6910890fbd52e95af53f67d2/Sources/SwiftBuildSupport/PackagePIFProjectBuilder.swift#L401-L403)
- Executables with their own resources also declare `PACKAGE_RESOURCE_BUNDLE_NAME`.
  Include the selected executable itself, not only linked libraries.
  [Executable resources](https://github.com/swiftlang/swift-package-manager/blob/18da3eb1e770679f6910890fbd52e95af53f67d2/Sources/SwiftBuildSupport/PackagePIFProjectBuilder%2BProducts.swift#L318-L344)
- Platform conditions attach to dependency and framework build-file entries.
  Linux filters expand to `linux/gnu` and `linux/musl`. Static Linux must match
  `linux/musl`, not a platform string of `staticlinux`.
  [Condition conversion](https://github.com/swiftlang/swift-package-manager/blob/18da3eb1e770679f6910890fbd52e95af53f67d2/Sources/SwiftBuildSupport/PackagePIFBuilder%2BHelpers.swift#L303-L319),
  [Linux filters](https://github.com/swiftlang/swift-build/blob/807b9cd2dc7a447cafe9a6612df47f95313f2877/Sources/SwiftBuild/ProjectModel/BuildSettings.swift#L289-L295)

An implementation can index targets by GUID, identify exactly one selected
executable product, traverse its active framework target references, and collect
resource names from the current configuration's settings. Cross-check each name
against the matching resource target and validated `<name>.bundle` directory.
Preserve existing path, symlink, duplicate, and missing-resource checks. Treat
unknown reference shapes, unresolved names, or ambiguous products as verification
errors. Retain the native verifier for older toolchains that use the native
default.

Resource metadata must come from the current build. A bundle directory can remain
after an earlier build. Its existence alone does not prove that the selected
product uses it. PIF contains inactive dynamic variants too, so scanning all
targets would overinclude resources.

## Isolated checks

The parent agent copied `Tests/TripleTests/Fixtures/CrossCompilationPackage` into
temporary storage and built it with Swift 6.4.0 and the exact Swift 6.4 SDK registry.
Both x86_64 and ARM64 release builds passed with the default build system, in
2.11 and 2.26 seconds. Neither emitted the native deprecation warning. The command
used the following form, with a separate scratch directory for each architecture:

```text
swiftly run swift build --package-path <temp>/package
  --scratch-path <temp>/build
  --swift-sdks-path <temp>/sdks
  --swift-sdk x86_64-swift-linux-musl
  --product CrossCompilationFixture --configuration release +6.4.0
```

The ARM64 selector was `aarch64-swift-linux-musl`. These checks establish that
Swift Build can cross-compile this resource fixture. They do not establish that
Triple's current verifier or exporter works with that output, or that the exported
Linux executable can find its resources at runtime.

The observed graph was:

```text
CrossCompilationFixture executable
  frameworks buildPhases -> ResourceDependency library product
    frameworksBuildPhase -> ResourceDependency module
      PACKAGE_RESOURCE_BUNDLE_NAME = ResourceDependency_ResourceDependency
      build dependency -> ResourceDependency resource bundle target
```

The x86_64 binary directory was `out/Products/Release-staticlinux-x86_64`.
`ResourceDependency.objlib/args.resp` listed the resource accessor object and the
library's source object. The executable's own `.LinkFileList` contained only its
main object. The bundle was `ResourceDependency_ResourceDependency.bundle` and
contained both `message.txt` and generated `Info.plist`.

A small Python traversal of the PIF used only framework `targetReference` edges
and Release settings. It found exactly `ResourceDependency_ResourceDependency.bundle`
for each architecture and confirmed that directory exists. This fixture has no
platform-filtered edges, so it does not validate condition pruning.

## Implementation and verification

Triple now omits the build-system override. `SwiftPMBuildOutput.inspect` selects
the verifier from the actual binary-directory layout. Native output retains its
existing link-file verification. Swift Build output uses the current scratch
directory's PIF and the selected build configuration. The decoder reads only
fields needed for resource selection, with no public build-system setting or
new dependency.

Tests cover linked module resources, executable resources, unrelated products,
stale bundles, host-only dependencies, platform filters, missing resources,
ambiguous products, malformed metadata, and privacy-only bundles.

All 352 library tests passed when built with Swift 6.4.0 and Swift 6.3.3. The
Swift 6.3.3 test build used the installed macOS 26.5 SDK.

Cross-compilation acceptance passed eight build/export combinations: Swift
6.3.3 and 6.4.0, ARM64 and x86_64 Linux, debug and release. The fixture includes
resources in both the executable and a library dependency. Each exported
directory retained the expected resource content after scratch storage was
removed. The consecutive-build artifact-identity test also passed.

Swift Build generates `Info.plist` for resource bundles. The privacy-only filter
now ignores a regular `Info.plist` in a `.bundle` after tree validation, but keeps
bundles with any other runtime content.
[Generated resource Info.plist setting](https://github.com/swiftlang/swift-package-manager/blob/18da3eb1e770679f6910890fbd52e95af53f67d2/Sources/SwiftBuildSupport/PackagePIFProjectBuilder.swift#L225-L238)

The initial 9 October checks verified the exported executables as ELF files
without executing them on Linux. The follow-up on 10 October ran Swift 6.3.3 and
6.4.0 release exports after their original scratch storage was removed. Both
executable and dependency resources loaded successfully on native x86_64 Linux
and ARM64 Linux through QEMU user-mode emulation. Commands and output are recorded
in [`Linux-resource-execution.md`](Linux-resource-execution.md).

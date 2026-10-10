# Triple

Build static Linux executables from Swift packages on your Mac.

Triple is a Swift library for apps and developer tools. It selects an official Swift toolchain and matching Static Linux SDK, builds your package for ARM64 or x86-64 Linux Musl, and returns a verified executable with its resource bundles.

For a terminal command, use [TripleCLI](https://github.com/mottzi/TripleCLI). For a graphical app, use [Triple app](https://github.com/mottzi/TripleApp). See [the website](https://triple.mottzi.codes/) for an overview.

## Requirements

- An Apple silicon Mac with macOS 13 or later
- Xcode or Command Line Tools with Swift 6.3 or later
- An unsandboxed app or command-line tool
- A local Swift package with an executable product and dependencies that support Linux Musl

Triple uses Swiftly 1.0 or later to manage toolchains and SDKs. It can install missing components. You must install Xcode or Command Line Tools yourself.

Build only packages you trust. SwiftPM evaluates manifests and can run plugins with your permissions.

## Install

Version `0.7.0` is prepared but not yet published. The version requirement below will work after publication. Older tags export the `SwiftlyKit` module.

In Xcode, add `https://github.com/mottzi/Triple.git` as a package dependency, select a version starting at `0.7.0`, and add the `Triple` product to your target.

For a Swift package, add the dependency and product. This complete manifest creates the runner used below:

```swift
// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "BuildLinux",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/mottzi/Triple.git", from: "0.7.0")
    ],
    targets: [
        .executableTarget(
            name: "BuildLinux",
            dependencies: [.product(name: "Triple", package: "Triple")]
        )
    ]
)
```

## Build and export

Save this as `Sources/BuildLinux/BuildLinux.swift` in the runner package:

```swift
import Foundation
import Triple

@main
struct BuildLinux {
    static func main() async throws {
        guard CommandLine.arguments.count == 3 else {
            print("Usage: BuildLinux <package-root> <output-directory>")
            return
        }

        let packageRoot = URL(filePath: CommandLine.arguments[1])
        let destination = URL(filePath: CommandLine.arguments[2])
        let result = try await Triple.build(
            packageRoot,
            output: .export(to: destination)
        )

        print("Executable: \(result.executable.path)")
    }
}
```

Run it with absolute paths. The package root must contain `Package.swift`. The output directory must not exist, and its parent directory must exist.

```sh
swift run BuildLinux /absolute/path/to/MyTool /absolute/path/to/output/MyTool
```

This builds the package's only executable product for x86-64 Linux in release mode. Triple can install missing tools, update Swiftly before a toolchain installation, and resolve dependencies. Resolution can change `Package.resolved`. Use the staged workflow below if your app must approve these changes first.

Copy the complete output directory to Linux with the selected architecture. Run the executable there. A Linux executable cannot run directly on macOS.

## Choose build options

Pass a product name when the package has more than one executable product:

```swift
let result = try await Triple.build(
    packageRoot,
    product: "MyTool",
    for: .linux(.arm64),
    toolchain: .exact(SwiftVersion(major: 6, minor: 3, patch: 3)),
    configuration: .release,
    jobs: 4,
    output: .export(to: destination),
    strip: true
)
```

| Option | Default | Use |
| --- | --- | --- |
| `product` | The only executable product | Select an executable by name. |
| `for` | `.linux(.x86_64)` | Select `.linux(.arm64)` for ARM64. |
| `toolchain` | `.automatic` | Select an official stable Swift release. |
| `configuration` | `.release` | Use `.debug` for a debug build. |
| `jobs` | SwiftPM default | Set a positive maximum job count. |
| `scratchStorage` | Package `.build` | Select a separate build directory. |
| `output` | `.buildStorage` | Export the executable and resources together. |
| `strip` | `false` | Remove symbols from a copy of the executable. |

Automatic selection uses a compatible version from the nearest `.swift-version` file first. Otherwise, it selects the newest compatible installed toolchain and SDK pair, then the newest compatible official stable release. An exact selection or `.swift-version` pin stays fixed.

## Control preparation and resolution

Use the staged API to show installation requirements before you accept them:

```swift
let kit = Triple()
let assessment = try await kit.assess(packageRoot, for: .linux(.arm64))
print(assessment.requiredComponents)

// Call after your app accepts the required preparation.
let environment = try await kit.prepare(assessment)
let configuration = try await kit.configurePackage(using: environment)
let product = try configuration.products.select("MyTool")
let result = try await kit.build(
    BuildRequest(product, output: .export(to: destination)),
    using: configuration.environment,
    dependencies: .resolveIfNeeded
)
```

Assessment does not install tools or resolve dependencies. Preparation installs accepted components. Configuration reads the root manifest without resolving dependencies. Use `configuration.environment` for the build to keep the host SDK that succeeded.

A staged build defaults to `.requireResolved`. Pass `.resolveIfNeeded` to permit dependency resolution. Call `prepare` even when no installation is required.

See [advanced usage](Documentation/Usage.md) for toolchain discovery, package traits, environment values, storage, cleanup, and installation recovery.

## Keep resources with the executable

`BuildResult.executable` is the verified Linux executable. `resourceBundles` contains its required resource bundles, including bundles from dependencies. Keep these files together. Export copies the complete runnable directory and checks it before committing the destination.

The default export rejects an existing destination. Use `policy: .replaceIfPresent` to replace it, or `.requireExistingEmptyDirectory` for an existing empty folder. You can also call `result.export(to:)` after a build without rebuilding.

Triple checks the ELF architecture and rejects dynamic interpreters and required dynamic libraries. It also checks resource files and rejects a build result if observed package sources changed during compilation. These checks do not prove that your program behaves correctly on Linux. Test it on the target system.

## Progress, errors, and cancellation

Use `onEvent` to show progress or forward command output:

```swift
let result = try await Triple.build(packageRoot, onEvent: { event in
    switch event {
    case .progress(let progress):
        print(progress.detail)
    case .output(let output):
        print(output.text, terminator: "")
    case .command:
        break
    @unknown default:
        break
    }
})
```

Triple awaits each event handler. Keep the handler short and do not start another mutating Triple operation from it. Use the operation's return or error to determine completion.

Cancel the task that calls Triple to stop the build and its subprocess group. Handle cancellation separately from operational errors:

```swift
do {
    let result = try await Triple.build(packageRoot)
    print(result.executable.path)
} catch is CancellationError {
    print("Build cancelled.")
} catch let error as TripleError {
    print(error.localizedDescription)
}
```

Triple allows only one operation to change tools or build files at a time for the same Mac user. Avoid direct `swift` or `swiftly` changes to the same package, tools, or output while Triple is working.

## Support and contributing

Open an [issue](https://github.com/mottzi/Triple/issues) for questions or bugs. Include the host macOS version, selected Swift version, target architecture, and relevant error output. Remove credentials from logs before sharing them.

See [advanced usage](Documentation/Usage.md) for the full workflow and [contributing](Documentation/Contributing.md) for development checks. To migrate from SwiftlyKit, change the product and import to `Triple`, and use `TripleEvent` and `TripleError`.

## License

[MIT](LICENSE).

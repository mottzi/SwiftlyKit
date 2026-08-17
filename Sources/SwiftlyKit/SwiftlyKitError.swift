import Foundation

/// Typed failures from coordination, host checks, environment preparation and removal,
/// package inspection, builds, and cleanup.
public enum SwiftlyKitError: Equatable, Sendable {

    /// SwiftlyKit could not establish safe coordination for a mutating workflow.
    case mutationCoordinationFailed(String)

    /// The package root is not a readable local directory with a UTF-8 `Package.swift` file.
    case invalidPackageRoot(URL)

    /// The host is not Apple silicon or runs a macOS version earlier than 13.
    case unsupportedHost

    /// The active developer tools do not provide a usable macOS SDK.
    case developerToolsUnavailable

    /// The explicit Command Line Tools installer request failed with the associated diagnostic.
    case commandLineToolsInstallationRequestFailed(String)

    /// `Package.swift` has no supported `swift-tools-version` declaration.
    case malformedToolsVersion

    /// The package tools version is newer than the selected Swift release,
    /// or a pre-Swift-6 directive follows a nonblank line.
    /// The associated value is the package tools version.
    case unsupportedToolsVersion(SwiftVersion)

    /// The Swiftly installation is incompatible or its installed state cannot be read.
    case incompatibleSwiftly

    /// Swiftly or a required component could not be installed or inspected during preparation.
    case swiftlyInstallationFailed(String)

    /// A required Swift.org catalog or package download failed.
    case networkFailure(String)

    /// Official release metadata or a downloaded installer failed integrity validation.
    case integrityCheckFailed(String)

    /// No official stable release matches the requested selection, tools version, and target architecture.
    case compatibleReleaseUnavailable

    /// The selected release has no matching SDK for the target, or the exact SDK bundle is unavailable.
    case staticLinuxSDKUnavailable

    /// The accepted assessment no longer matches the current package or installed state.
    case staleAssessment

    /// A SwiftPM process value has an invalid name, value, or protected purpose.
    case invalidSwiftPMEnvironmentVariable(String)

    /// A SwiftPM package trait has an invalid or reserved name.
    case invalidSwiftPMTrait(String)

    /// SwiftPM could not return usable package metadata.
    case packageInspectionFailed(String)

    /// The build requires explicit package dependency resolution before a retry.
    case dependencyResolutionRequired

    /// SwiftPM could not resolve package dependencies.
    case dependencyResolutionFailed(String)

    /// Sole-product selection failed because the package declares zero or multiple executable products.
    /// The associated array contains available product names in name order.
    case executableProductSelectionRequired([String])

    /// SwiftPM metadata or build output does not contain the requested executable product.
    case executableProductNotFound(String)

    /// SwiftlyKit could not prove or verify the selected product's runtime resource output.
    case runtimeResourceVerificationFailed

    /// The explicit maximum SwiftPM build job count is not positive.
    case invalidBuildJobCount(Int)

    /// SwiftPM could not prepare the exact SDK search path or build the executable.
    case buildFailed(String)

    /// Relevant package source or dependency state changed while SwiftlyKit built the executable.
    case packageChangedDuringBuild

    /// SwiftlyKit could not establish build-time source stability for the associated reason.
    case packageSourceStabilityUnavailable(String)

    /// The selected toolchain could not strip the executable.
    case stripFailed(String)

    /// The output is not a verified static ELF64 executable for the requested architecture.
    case executableVerificationFailed(String)

    /// The selected build storage contains the package root and could remove package sources.
    case unsafeBuildStorage(URL)

    /// An explicit SwiftPM shared-storage location is invalid or overlaps selected scratch storage.
    case unsafeSwiftPMSharedStorage(URL)

    /// Automatic cleanup cannot preserve an output located inside build storage.
    case outputInsideBuildStorage(URL)

    /// The publication destination already exists and was not replaced.
    case outputAlreadyExists(URL)

    /// SwiftlyKit could not atomically publish the runnable directory to the destination.
    case outputPublicationFailed(URL)

    /// The published directory remains at the associated output URL, but the requested post-build cleanup failed.
    case postBuildCleanupFailed(output: URL, detail: String)

    /// SwiftPM could not remove compiled products and intermediate build artifacts.
    case buildArtifactCleanupFailed(String)

    /// SwiftPM could not remove the complete effective scratch directory.
    case buildStorageResetFailed(String)

    /// SwiftlyKit refused an environment removal because the requested scope was unsafe.
    case unsafeEnvironmentRemoval(String)

    /// An environment removal command or its postcondition failed.
    case environmentRemovalFailed(String)

}

extension SwiftlyKitError: LocalizedError {

    /// A user-facing description of the failure.
    public var errorDescription: String? {
        switch self {
            case .mutationCoordinationFailed(let detail):
                "SwiftlyKit could not coordinate mutations: \(detail)"

            case .invalidPackageRoot:
                "The package root must be a readable local directory containing Package.swift."

            case .unsupportedHost:
                "SwiftlyKit requires Apple silicon macOS 13 or later."

            case .developerToolsUnavailable:
                "A usable macOS SDK is unavailable; install or select Xcode or Command Line Tools."

            case .commandLineToolsInstallationRequestFailed(let detail):
                "The Command Line Tools installation could not be requested: \(detail)"

            case .malformedToolsVersion:
                "Package.swift does not contain a supported swift-tools-version declaration."

            case .unsupportedToolsVersion(let version):
                "No supported official Swift release is compatible with tools version \(version)."

            case .incompatibleSwiftly:
                "Swiftly 1.0 or later is required; an existing Swiftly installation is not replaced automatically."

            case .swiftlyInstallationFailed(let detail):
                "Swiftly could not be installed: \(detail)"

            case .networkFailure(let detail):
                "A required download failed: \(detail)"

            case .integrityCheckFailed(let detail):
                "A downloaded component could not be trusted: \(detail)"

            case .compatibleReleaseUnavailable:
                "No compatible official stable Swift release and Static Linux SDK are available."

            case .staticLinuxSDKUnavailable:
                "The exact selected Static Linux SDK is unavailable."

            case .staleAssessment:
                "Package.swift or .swift-version changed after the environment was assessed."

            case .invalidSwiftPMEnvironmentVariable(let name):
                "The SwiftPM environment variable “\(name)” is invalid or protected."

            case .invalidSwiftPMTrait(let name):
                "The SwiftPM package trait “\(name)” has an invalid or reserved name."

            case .packageInspectionFailed(let detail):
                "SwiftPM could not inspect the package: \(detail)"

            case .dependencyResolutionRequired:
                "Package dependencies must be resolved explicitly before building."

            case .dependencyResolutionFailed(let detail):
                "SwiftPM could not resolve package dependencies: \(detail)"

            case .executableProductSelectionRequired(let products) where products.isEmpty:
                "The package does not declare an executable product."

            case .executableProductSelectionRequired(let products):
                "The package declares multiple executable products; specify one of: \(products.joined(separator: ", "))."

            case .executableProductNotFound(let product):
                "SwiftPM did not produce the executable product “\(product)”."

            case .runtimeResourceVerificationFailed:
                "The selected product's runtime resource output could not be verified."

            case .invalidBuildJobCount(let count):
                "The maximum SwiftPM build job count must be positive; received \(count)."

            case .buildFailed(let detail):
                "SwiftPM could not build the executable: \(detail)"

            case .packageChangedDuringBuild:
                "Package source or dependency state changed during the build; build again from stable inputs."

            case .packageSourceStabilityUnavailable(let detail):
                "SwiftlyKit could not establish package-source stability: \(detail)"

            case .stripFailed(let detail):
                "The executable could not be stripped: \(detail)"

            case .executableVerificationFailed(let detail):
                "The produced executable failed verification: \(detail)"

            case .unsafeBuildStorage(let url):
                "Build storage at \(url.path(percentEncoded: false)) must not contain the package root."

            case .unsafeSwiftPMSharedStorage(let url):
                "SwiftPM shared storage at \(url.path(percentEncoded: false)) must be an absolute local directory "
                    + "outside the selected scratch storage."

            case .outputInsideBuildStorage(let url):
                "The output at \(url.path(percentEncoded: false)) must be outside build storage when cleanup is requested."

            case .outputAlreadyExists(let url):
                "The output already exists at \(url.path(percentEncoded: false))."

            case .outputPublicationFailed(let url):
                "The runnable output could not be published to \(url.path(percentEncoded: false))."

            case .postBuildCleanupFailed(let output, let detail):
                """
                The runnable directory was published to \(output.path(percentEncoded: false)), \
                but build storage cleanup failed: \(detail)
                """

            case .buildArtifactCleanupFailed(let detail):
                "SwiftPM could not clean build artifacts: \(detail)"

            case .buildStorageResetFailed(let detail):
                "SwiftPM could not reset build storage: \(detail)"

            case .unsafeEnvironmentRemoval(let detail):
                "SwiftlyKit refused to remove the environment: \(detail)"

            case .environmentRemovalFailed(let detail):
                "SwiftlyKit could not remove the environment: \(detail)"
        }
    }

}

import Foundation

/// Immutable host facts used by the read-only preflight.
struct HostFacts: Sendable {

    let isAppleSilicon: Bool
    let operatingSystemVersion: OperatingSystemVersion

}

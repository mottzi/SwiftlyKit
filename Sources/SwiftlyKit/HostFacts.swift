import Foundation

/// Immutable host facts used by the read-only preflight.
struct HostFacts: Sendable {
    
    let isAppleSilicon: Bool
    let operatingSystemVersion: OperatingSystemVersion
    
}

extension HostFacts {
    
    static var live: HostFacts {
        #if arch(arm64)
            let isAppleSilicon = true
        #else
            let isAppleSilicon = false
        #endif
        
        return HostFacts(
            isAppleSilicon: isAppleSilicon,
            operatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersion
        )
    }
    
}

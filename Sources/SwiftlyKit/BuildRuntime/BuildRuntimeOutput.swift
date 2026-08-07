enum BuildRuntimeOutputStream: Sendable {
    
    case standardOutput
    case standardError
    
}

typealias BuildRuntimeOutputHandler = @Sendable (BuildRuntimeOutputStream, String) async -> Void

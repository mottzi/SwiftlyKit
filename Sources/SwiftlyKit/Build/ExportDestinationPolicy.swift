/// The destination changes permitted when a runnable directory is exported.
public enum ExportDestinationPolicy: Sendable, Equatable {

    /// Creates a new directory and rejects any existing destination.
    case createNewDirectory

    /// Creates the directory if missing, or replaces the existing destination and its contents.
    case replaceIfPresent

    /// Requires an existing empty directory when export commits.
    /// If another process adds contents first, export fails without overwriting them.
    case requireExistingEmptyDirectory

}

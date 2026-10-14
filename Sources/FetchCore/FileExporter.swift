import Foundation

public enum FileExporter {
    /// Copy off the main thread and replace an existing destination only after staging succeeds.
    public static func copy(source: URL, destination: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            guard source.resolvingSymlinksInPath().standardizedFileURL != destination.resolvingSymlinksInPath().standardizedFileURL else {
                throw ServiceError.message("This file is already in that location.")
            }
            let stage = destination.deletingLastPathComponent().appendingPathComponent(".fetch-copy-" + UUID().uuidString)
            defer { try? fm.removeItem(at: stage) }
            try fm.copyItem(at: source, to: stage)
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: stage)
            } else { try fm.moveItem(at: stage, to: destination) }
        }.value
    }
}

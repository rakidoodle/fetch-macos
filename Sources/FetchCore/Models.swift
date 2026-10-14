import Foundation

public enum DownloadKind: String, Codable, CaseIterable, Identifiable {
    case web, youtube, torrent
    public var id: String { rawValue }
    public var title: String { switch self { case .web: return "Web file"; case .youtube: return "YouTube"; case .torrent: return "Torrent" } }
    public var symbol: String { switch self { case .web: return "globe"; case .youtube: return "play.rectangle"; case .torrent: return "point.3.connected.trianglepath.dotted" } }
    public static func detect(_ source: String) -> Self {
        let value = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("magnet:") { return .torrent }
        guard let url = URL(string: value) else { return .web }
        if url.path.lowercased().hasSuffix(".torrent") { return .torrent }
        if ["youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com", "youtu.be"].contains(url.host?.lowercased() ?? "") { return .youtube }
        return .web
    }
}
public struct DownloadFile: Codable, Identifiable, Equatable {
    public let name: String
    public let path: String
    public let size: Double?
    public var id: String { path }
}
public struct DownloadJob: Codable, Identifiable, Equatable {
    public let id: String
    public let type: DownloadKind
    public let source: String
    public let mode: String?
    public let resolution: String?
    public let format: String?
    public let quality: String?
    public let name: String
    public let status: String
    public let created: Double
    public let finished: Double?
    public let total: Double
    public let completed: Double
    public let speed: Double
    public let connections: Int
    public let seeders: Int?
    public let eta: Double?
    public let segments: [Double]
    public let files: [DownloadFile]
    public let error: String?
    public var isActive: Bool { ["downloading", "processing"].contains(status) }
    public var canPause: Bool { isActive || status == "queued" }
    public var canResume: Bool { ["paused", "error", "canceled"].contains(status) }
    public var canCancel: Bool { !["completed", "canceled"].contains(status) }
    public var canRemove: Bool { !isActive && status != "queued" }
    public var progress: Double { total > 0 ? min(1, max(0, completed / total)) : 0 }
    public var statusTitle: String {
        switch status {
        case "downloading": return "Downloading"
        case "processing": return "Processing media"
        case "queued": return "Queued"
        case "paused": return "Paused"
        case "completed": return "Completed"
        case "canceled": return "Canceled"
        case "error": return "Needs attention"
        default: return status.capitalized
        }
    }
}
public struct TransferSettings: Codable, Equatable {
    public var connections: Int
    public var maxActive: Int
    public var speedLimit: Int
    public init(connections: Int = 8, maxActive: Int = 3, speedLimit: Int = 0) { self.connections = connections; self.maxActive = maxActive; self.speedLimit = speedLimit }
    public var isValid: Bool { (1...16).contains(connections) && (1...8).contains(maxActive) && (0...1_000_000).contains(speedLimit) }
}
public struct EngineStatus: Codable {
    public let aria2: Bool
    public let youtube: Bool
    public let ffmpeg: Bool
    public var allReady: Bool { aria2 && youtube && ffmpeg }
}
public struct TransferEvent: Codable, Identifiable {
    public let id: String
    public let jobId: String?
    public let name: String
    public let verb: String
    public let time: Double
    public let type: DownloadKind
}
public struct ServiceState: Codable {
    public let jobs: [DownloadJob]
    public let settings: TransferSettings
    public let engines: EngineStatus
    public let events: [TransferEvent]
    public let downloadDir: String
    public let key: String
    public let error: String?
}
public struct AddRequest: Codable {
    public var type: DownloadKind
    public var source: String
    public var mode: String?
    public var resolution: String?
    public var format: String?
    public var torrent: String?
    public var name: String?
    public init(type: DownloadKind, source: String, mode: String? = nil, resolution: String? = nil, format: String? = nil, torrent: String? = nil, name: String? = nil) {
        self.type = type; self.source = source; self.mode = mode; self.resolution = resolution; self.format = format; self.torrent = torrent; self.name = name
    }
    public var validationError: String? {
        if type == .torrent, let torrent, !torrent.isEmpty { return nil }
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "Enter a download link." }
        guard text.count <= 8192, let url = URL(string: text), let scheme = url.scheme?.lowercased() else { return "Enter a valid URL." }
        if url.user != nil || url.password != nil { return "Links with embedded credentials are not supported." }
        if type == .torrent && scheme == "magnet" {
            guard let hash = URLComponents(string: text)?.queryItems?.first(where: { $0.name == "xt" })?.value,
                  hash.range(of: "^urn:btih:([a-fA-F0-9]{40}|[a-zA-Z2-7]{32})$", options: .regularExpression) != nil else { return "Magnet link needs a valid BitTorrent info hash." }
            return nil
        }
        guard ["http", "https"].contains(scheme), url.host != nil else { return "Only HTTP and HTTPS links are supported." }
        if type == .torrent && !url.path.lowercased().hasSuffix(".torrent") { return "Use a magnet link, .torrent URL, or choose a torrent file." }
        if type == .youtube && DownloadKind.detect(text) != .youtube { return "Enter a YouTube video URL." }
        return nil
    }
}
public enum LibrarySection: String, CaseIterable, Identifiable {
    case all, active, web, youtube, torrent, completed, paused, attention
    public var id: String { rawValue }
    public var title: String { switch self { case .all: return "All downloads"; case .active: return "In progress"; case .web: return "Web files"; case .youtube: return "YouTube"; case .torrent: return "Torrents"; case .completed: return "Completed"; case .paused: return "Paused"; case .attention: return "Needs attention" } }
    public var symbol: String { switch self { case .all: return "tray.full"; case .active: return "arrow.down.circle"; case .web: return "globe"; case .youtube: return "play.rectangle"; case .torrent: return "point.3.connected.trianglepath.dotted"; case .completed: return "checkmark.circle"; case .paused: return "pause.circle"; case .attention: return "exclamationmark.circle" } }
    public func includes(_ job: DownloadJob) -> Bool {
        switch self { case .all: return true; case .active: return job.isActive || job.status == "queued"; case .web, .youtube, .torrent: return job.type.rawValue == rawValue; case .completed: return job.status == "completed"; case .paused: return job.status == "paused"; case .attention: return job.status == "error" }
    }
}
public enum DownloadSort: String, CaseIterable, Identifiable {
    case newest, oldest, name, size
    public var id: String { rawValue }
    public var title: String { switch self { case .newest: return "Newest first"; case .oldest: return "Oldest first"; case .name: return "Name"; case .size: return "Largest first" } }
    public func sorted(_ jobs: [DownloadJob]) -> [DownloadJob] {
        jobs.sorted { a, b in
            switch self { case .newest: return a.created != b.created ? a.created > b.created : a.id < b.id; case .oldest: return a.created != b.created ? a.created < b.created : a.id < b.id; case .name: return a.name.localizedStandardCompare(b.name) == .orderedAscending; case .size: return a.total != b.total ? a.total > b.total : a.id < b.id }
        }
    }
}
public enum DisplayFormat {
    public static func bytes(_ value: Double) -> String {
        guard value.isFinite, value > 0 else { return "0 B" }
        return ByteCountFormatter.string(fromByteCount: Int64(min(value, Double(Int64.max - 1024))), countStyle: .file)
    }
    public static func eta(_ value: Double?) -> String {
        guard let value, value.isFinite, value > 0 else { return "Estimating…" }
        if value < 60 { return "\(Int(ceil(value)))s remaining" }
        if value < 3600 { return "\(Int(ceil(value / 60)))m remaining" }
        return "\(Int(value / 3600))h \(Int(ceil(value.truncatingRemainder(dividingBy: 3600) / 60)))m remaining"
    }
    public static func safeFile(_ file: DownloadFile, job: DownloadJob, downloadDir: String) throws -> URL {
        guard UUID(uuidString: job.id) != nil else { throw ServiceError.message("Invalid download identifier.") }
        let root = URL(fileURLWithPath: downloadDir).appendingPathComponent(job.id, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        let target = URL(fileURLWithPath: file.path).resolvingSymlinksInPath().standardizedFileURL
        guard target.path.hasPrefix(root.path + "/"), (try? target.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { throw ServiceError.message("File was moved, deleted, or is outside this download folder.") }
        return target
    }
}
public enum ServiceError: LocalizedError {
    case message(String)
    public var errorDescription: String? { switch self { case .message(let text): return text } }
}

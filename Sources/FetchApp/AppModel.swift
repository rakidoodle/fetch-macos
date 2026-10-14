import SwiftUI
import AppKit
import UniformTypeIdentifiers
import FetchCore

@MainActor final class AppModel: ObservableObject {
    static let shared = AppModel()
    @Published var state: ServiceState?
    @Published var section: LibrarySection = .all
    @Published var search = ""
    @Published var sort: DownloadSort = .newest
    @Published var statusFilter = "all"
    @Published var selectedID: String?
    @Published var showAdd = false
    @Published var showInspector = false
    @Published var pending = Set<String>()
    @Published var notice: String?
    @Published var failure: String?
    @Published var startupError: String?
    @Published var online = false
    @Published var starting = false
    @Published var copyingCount = 0
    @Published var quitting = false
    private let bridge = BackendBridge()
    private var client: ServiceClient?
    private var pollTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    var resources: URL { Bundle.main.resourceURL! }
    var dataDir: URL {
        if let value = ProcessInfo.processInfo.environment["FETCH_TEST_DATA_DIR"] { return URL(fileURLWithPath: value) }
        if Bundle.main.bundleIdentifier?.hasSuffix(".verification") == true, let value = Bundle.main.object(forInfoDictionaryKey: "FetchVerificationDataDir") as? String { return URL(fileURLWithPath: value) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Fetch", isDirectory: true)
    }
    var downloadDir: URL {
        if let value = ProcessInfo.processInfo.environment["FETCH_TEST_DOWNLOAD_DIR"] { return URL(fileURLWithPath: value) }
        if Bundle.main.bundleIdentifier?.hasSuffix(".verification") == true, let value = Bundle.main.object(forInfoDictionaryKey: "FetchVerificationDownloadDir") as? String { return URL(fileURLWithPath: value) }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].appendingPathComponent("Fetch", isDirectory: true)
    }
    var jobs: [DownloadJob] { state?.jobs ?? [] }
    var selected: DownloadJob? { jobs.first { $0.id == selectedID } }
    var visibleJobs: [DownloadJob] {
        sort.sorted(jobs.filter { section.includes($0) && (statusFilter == "all" || $0.status == statusFilter) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.source.localizedCaseInsensitiveContains(search)) })
    }
    var totalSpeed: Double { jobs.reduce(0) { $0 + $1.speed } }
    var activeCount: Int { jobs.filter(\.isActive).count }
    func count(_ value: LibrarySection) -> Int { jobs.filter(value.includes).count }
    func start() async {
        guard client == nil, !starting, !quitting else { return }
        starting = true; startupError = nil
        defer { starting = false }
        do {
            let service = try await bridge.start(resources: resources, dataDir: dataDir, downloadDir: downloadDir)
            guard !quitting else { await bridge.stop(); return }
            client = service
            try await refresh()
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    guard !Task.isCancelled, let self else { break }
                    do { try await self.refresh() } catch { self.online = false }
                }
            }
        } catch { startupError = error.localizedDescription; online = false }
    }
    func refresh() async throws {
        guard let client else { throw ServiceError.message("Download service is starting.") }
        let latest = try await client.state()
        state = latest; online = true
        if let selectedID, !latest.jobs.contains(where: { $0.id == selectedID }) { self.selectedID = nil }
    }
    func restart() async {
        pollTask?.cancel(); pollTask = nil; client = nil; online = false
        await bridge.stop()
        await start()
    }
    func stop() async {
        quitting = true
        pollTask?.cancel(); pollTask = nil
        noticeTask?.cancel()
        await bridge.stop(); client = nil
        // Keep the process alive until atomic file exports finish.
        while copyingCount > 0 { try? await Task.sleep(nanoseconds: 100_000_000) }
    }
    func add(_ request: AddRequest) async throws {
        guard let client, online else { throw ServiceError.message("Download service is unavailable. Restart the service, then try again.") }
        let id = try await client.add(request)
        try await refresh()
        section = .all; statusFilter = "all"; search = ""; selectedID = id
        notify("Download added.")
    }
    func analyzeVideo(_ source: String) async throws -> VideoInfo {
        guard let client, online else { throw ServiceError.message("Download service is unavailable.") }
        return try await client.analyzeVideo(source)
    }
    func action(_ job: DownloadJob, _ action: String) async {
        guard let client, online, !pending.contains(job.id) else { return }
        pending.insert(job.id)
        defer { pending.remove(job.id) }
        do {
            try await client.action(job.id, action)
            try await refresh()
            if action == "remove" { notify("Removed from history. Files remain on disk.") }
        } catch { failure = error.localizedDescription }
    }
    func updateSettings(_ settings: TransferSettings) async throws {
        guard let client, online else { throw ServiceError.message("Download service is unavailable. Restart it before saving settings.") }
        try await client.settings(settings)
        try await refresh(); notify("Transfer settings saved.")
    }
    func bulk(_ action: String) async {
        for job in jobs where action == "pause" ? job.canPause : job.status == "paused" {
            await self.action(job, action)
        }
    }
    func notify(_ text: String) {
        noticeTask?.cancel(); notice = text
        noticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled { self?.notice = nil }
        }
    }
    func reveal(_ file: DownloadFile, job: DownloadJob) {
        do {
            let target = try DisplayFormat.safeFile(file, job: job, downloadDir: state?.downloadDir ?? downloadDir.path)
            NSWorkspace.shared.activateFileViewerSelecting([target])
        } catch { failure = error.localizedDescription }
    }
    func saveCopy(_ file: DownloadFile, job: DownloadJob) {
        do {
            let source = try DisplayFormat.safeFile(file, job: job, downloadDir: state?.downloadDir ?? downloadDir.path)
            let panel = NSSavePanel()
            panel.title = "Save a copy"
            panel.nameFieldStringValue = file.name
            panel.canCreateDirectories = true
            panel.begin { [weak self] response in
                guard response == .OK, let target = panel.url else { return }
                Task { @MainActor in
                    do {
                        self?.copyingCount += 1
                        defer { self?.copyingCount -= 1 }
                        try await FileExporter.copy(source: source, destination: target)
                        self?.notify("Copy saved to \(target.lastPathComponent).")
                    } catch { self?.failure = error.localizedDescription }
                }
            }
        } catch { failure = error.localizedDescription }
    }
    func openDownloads() {
        if !NSWorkspace.shared.open(downloadDir) { failure = "Cannot open the download folder. Check its permissions in Finder." }
    }
    func importTorrent() async throws -> (String, String)? {
        let panel = NSOpenPanel()
        panel.title = "Choose a torrent file"
        panel.allowedContentTypes = [.init(filenameExtension: "torrent") ?? .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        let response: NSApplication.ModalResponse = await withCheckedContinuation { continuation in panel.begin { continuation.resume(returning: $0) } }
        guard response == .OK, let url = panel.url else { return nil }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 5_000_000 else { throw ServiceError.message("Choose a torrent file smaller than 5 MB.") }
        let data = try Data(contentsOf: url)
        guard data.first == 100, data.last == 101 else { throw ServiceError.message("This file is not a valid torrent.") }
        return (url.lastPathComponent, data.base64EncodedString())
    }
}

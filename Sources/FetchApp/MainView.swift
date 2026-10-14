import SwiftUI
import AppKit
import FetchCore

struct MainView: View {
    @EnvironmentObject var store: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var section: LibrarySection? = .all
    @State private var removeJob: DownloadJob?
    @State private var incomingLink = ""
    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(selection: $section) {
                    Section("Library") {
                        ForEach([LibrarySection.all, .active, .completed, .paused, .attention]) { item in sidebarRow(item) }
                    }
                    Section("Sources") {
                        ForEach([LibrarySection.web, .video, .youtube, .torrent]) { item in sidebarRow(item) }
                    }
                }
                .listStyle(.sidebar)
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 9) {
                    Label("On your Mac", systemImage: "internaldrive").font(.system(size: 12, weight: .medium))
                    Text("Files stay in your Downloads folder.").font(.system(size: 11)).foregroundStyle(Color(nsColor: NativePalette.secondary)).fixedSize(horizontal: false, vertical: true)
                    Button { store.openDownloads() } label: { Label("Open download folder", systemImage: "folder") }.buttonStyle(.link).font(.system(size: 12))
                }
                .padding(18)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 215, max: 260)
        } detail: {
            VStack(spacing: 0) {
                if let startupError = store.startupError {
                    serviceIssue(startupError)
                } else if store.starting && store.state == nil {
                    VStack(spacing: 14) { ProgressView(); Text("Starting download engines…").foregroundStyle(Color(nsColor: NativePalette.secondary)) }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    if !store.online && store.state != nil { offlineBar }
                    if let error = store.state?.error { Text(error).foregroundStyle(Color(nsColor: NativePalette.error)).font(.callout).padding(10).frame(maxWidth: .infinity, alignment: .leading).background(.red.opacity(0.07)) }
                    HStack(spacing: 0) {
                        library
                        if store.showInspector, let job = store.selected {
                            Divider()
                            InspectorView(job: job, remove: { removeJob = job }).id(job.id).frame(width: 280)
                        }
                    }
                    statusBar
                }
            }
            .navigationTitle(store.section.title)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Menu {
                        Picker("Sort downloads", selection: $store.sort) { ForEach(DownloadSort.allCases) { Text($0.title).tag($0) } }
                        Divider()
                        Picker("Filter by status", selection: $store.statusFilter) {
                            Text("All states").tag("all")
                            Text("Downloading").tag("downloading")
                            Text("Queued").tag("queued")
                            Text("Paused").tag("paused")
                            Text("Completed").tag("completed")
                            Text("Needs attention").tag("error")
                            Text("Canceled").tag("canceled")
                        }
                    } label: { Image(systemName: "line.3.horizontal.decrease") }
                    .help("Sort and filter downloads").accessibilityLabel("Sort and filter downloads")
                    Button { store.showInspector.toggle() } label: { Image(systemName: "sidebar.right") }.help("Show inspector").accessibilityLabel("Show inspector")
                    Button { incomingLink = ""; store.showAdd = true } label: { Label("New download", systemImage: "plus") }.help("New download (⌘N)").disabled(!store.online)
                }
                ToolbarItem(placement: .automatic) {
                    NativeSearchField(text: $store.search).frame(width: 190)
                }
            }
        }
        .frame(minWidth: 820, minHeight: 560)
        .sheet(isPresented: $store.showAdd, onDismiss: { incomingLink = "" }) { AddDownloadView(initialSource: incomingLink).environmentObject(store) }
        .alert("Remove from history?", isPresented: Binding(get: { removeJob != nil }, set: { if !$0 { removeJob = nil } }), presenting: removeJob) { job in
            Button("Cancel", role: .cancel) { removeJob = nil }
            Button("Remove", role: .destructive) { Task { await store.action(job, "remove") }; removeJob = nil }
        } message: { job in Text("\(job.name) will leave the library. Downloaded files remain on disk.") }
        .alert("Action could not finish", isPresented: Binding(get: { store.failure != nil }, set: { if !$0 { store.failure = nil } })) { Button("OK") { store.failure = nil } } message: { Text(store.failure ?? "") }
        .onChange(of: section) { _, value in if let value { store.section = value } }
        .onChange(of: store.section) { _, value in section = value }
        .onReceive(NotificationCenter.default.publisher(for: .fetchIncomingURL)) { notification in
            incomingLink = notification.object as? String ?? ""; store.showAdd = true
        }
    }
    func sidebarRow(_ item: LibrarySection) -> some View {
        HStack {
            Label(item.title, systemImage: item.symbol)
            Spacer()
            let count = store.count(item)
            if count > 0 { Text("\(count)").font(.system(size: 11).monospacedDigit()).foregroundStyle(Color(nsColor: NativePalette.secondary)) }
        }.tag(item).accessibilityElement(children: .ignore).accessibilityLabel("\(item.title), \(store.count(item)) downloads")
    }
    var library: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.section.title).font(.system(size: 24, weight: .semibold))
                    Text(librarySubtitle).font(.system(size: 13)).foregroundStyle(Color(nsColor: NativePalette.secondary))
                }
                Spacer()
                if store.activeCount > 0 {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(DisplayFormat.bytes(store.totalSpeed) + "/s").font(.system(size: 17, weight: .medium).monospacedDigit())
                        Text("\(store.activeCount) active").font(.system(size: 12)).foregroundStyle(Color(nsColor: NativePalette.secondary))
                    }
                }
            }.padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 20)
            if store.visibleJobs.isEmpty { emptyState }
            else {
                List(selection: $store.selectedID) {
                    ForEach(store.visibleJobs) { job in
                        TransferRow(job: job).frame(height: job.status == "error" ? 104 : 82).tag(job.id)
                            .contextMenu { JobMenu(job: job, remove: { removeJob = job }) }
                    }
                }
                .listStyle(.inset)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    var librarySubtitle: String {
        if !store.search.isEmpty { return "\(store.visibleJobs.count) results for “\(store.search)”" }
        if store.statusFilter != "all" { return "Filtered by \(store.statusFilter == "error" ? "needs attention" : store.statusFilter)" }
        return store.jobs.isEmpty ? "A home for everything you download." : "\(store.visibleJobs.count) \(store.visibleJobs.count == 1 ? "download" : "downloads") · Files, video, and torrents"
    }
    var emptyState: some View {
        VStack(spacing: 16) {
            if let image = NSImage(contentsOf: store.resources.appendingPathComponent("empty-library.png")) {
                Image(nsImage: image).resizable().scaledToFit().frame(width: 170, height: 140).accessibilityHidden(true)
            } else { Image(systemName: "tray.and.arrow.down").font(.system(size: 52, weight: .ultraLight)).foregroundStyle(.tint).padding(24).accessibilityHidden(true) }
            VStack(spacing: 8) {
                Text(store.jobs.isEmpty ? "Ready when you are." : "No matching downloads").font(.system(size: 20, weight: .semibold))
                Text(store.jobs.isEmpty ? "Add a file link, a video page, or a torrent.\nFetch takes care of the transfer." : "Try another search or choose All downloads.")
                    .font(.system(size: 13)).foregroundStyle(Color(nsColor: NativePalette.secondary)).multilineTextAlignment(.center)
            }
            if store.jobs.isEmpty {
                Button("New Download…") { store.showAdd = true }.buttonStyle(.borderedProminent).controlSize(.large).disabled(!store.online)
                Text("⌘N to add a download").font(.system(size: 11)).foregroundStyle(Color(nsColor: NativePalette.secondary))
            } else {
                Button("Show All Downloads") { store.search = ""; store.statusFilter = "all"; store.section = .all }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
    }
    var statusBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                Image(systemName: store.online && (store.state?.engines.allReady ?? false) ? "checkmark.shield" : "exclamationmark.triangle")
                    .foregroundStyle(store.online && (store.state?.engines.allReady ?? false) ? Color(nsColor: NativePalette.secondary) : Color.orange).accessibilityHidden(true)
                Text(store.copyingCount > 0 ? "Saving \(store.copyingCount) \(store.copyingCount == 1 ? "copy" : "copies")…" : (store.notice ?? (store.online ? ((store.state?.engines.allReady ?? false) ? "All engines ready" : "An engine is unavailable — check Settings") : "Service unavailable")))
                    .lineLimit(2).accessibilityLabel(store.notice ?? "Download engine status")
                Spacer()
                Text("\(store.jobs.filter { $0.status == "queued" }.count) queued").monospacedDigit()
                Button { store.openDownloads() } label: { Image(systemName: "folder") }.buttonStyle(.plain).help("Open download folder").accessibilityLabel("Open download folder")
            }.font(.system(size: 11)).foregroundStyle(Color(nsColor: NativePalette.secondary)).padding(.horizontal, 20).padding(.vertical, 10)
        }
    }
    var offlineBar: some View {
        HStack { Label("Download service disconnected.", systemImage: "exclamationmark.triangle"); Spacer(); Button("Restart Service") { Task { await store.restart() } }.disabled(store.starting) }
            .font(.callout).padding(12).background(.orange.opacity(0.1))
    }
    func serviceIssue(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            Label("Download service could not start", systemImage: "exclamationmark.triangle").font(.title2)
            Text(error).font(.callout).textSelection(.enabled)
            Button("Retry") { Task { await store.restart() } }.buttonStyle(.borderedProminent)
            Button("Open Service Logs") { NSWorkspace.shared.open(store.dataDir.appendingPathComponent("logs")) }
        }.padding(36).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}
struct TransferRow: View {
    @EnvironmentObject var store: AppModel
    let job: DownloadJob
    var color: Color { job.status == "error" ? .red : job.status == "completed" ? .green : .accentColor }
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: fileSymbol).font(.system(size: 24, weight: .light)).foregroundStyle(color).frame(width: 38, height: 44).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline) {
                    Text(job.name).font(.system(size: 14, weight: .medium)).lineLimit(1).help(job.name)
                    Spacer(minLength: 8)
                    Label(job.statusTitle, systemImage: statusSymbol).font(.system(size: 11)).foregroundStyle(job.status == "error" ? Color(nsColor: NativePalette.error) : Color(nsColor: NativePalette.secondary))
                }
                if job.isActive || ["paused", "queued"].contains(job.status) {
                    if job.status == "processing" { ProgressView().progressViewStyle(.linear) }
                    else { ProgressView(value: job.progress).tint(color).accessibilityLabel("Download progress").accessibilityValue("\(Int(job.progress * 100)) percent") }
                }
                HStack(spacing: 8) {
                    Text(job.type.title)
                    Text(job.total > 0 ? "\(DisplayFormat.bytes(job.completed)) of \(DisplayFormat.bytes(job.total))" : "Waiting for file details")
                        .monospacedDigit()
                    Spacer(minLength: 4)
                    if job.isActive && job.status != "processing" { Text(DisplayFormat.bytes(job.speed) + "/s").monospacedDigit(); Text(DisplayFormat.eta(job.eta)).monospacedDigit() }
                }.font(.system(size: 11)).foregroundStyle(Color(nsColor: NativePalette.secondary)).lineLimit(1)
                if let error = job.error, job.status == "error" { Text(error).font(.system(size: 12)).foregroundStyle(Color(nsColor: NativePalette.error)).lineLimit(2).help(error) }
            }
            HStack(spacing: 8) {
                if job.canPause { rowButton("Pause download", symbol: "pause.fill", action: "pause") }
                if job.canResume { rowButton(job.status == "paused" ? "Resume download" : "Retry download", symbol: job.status == "paused" ? "play.fill" : "arrow.clockwise", action: "resume") }
                if job.status == "completed", let file = job.files.first {
                    Button { store.reveal(file, job: job) } label: { Image(systemName: "folder") }.help("Show in Finder").accessibilityLabel("Show \(job.name) in Finder")
                }
                Button { store.selectedID = job.id; store.showInspector = true } label: { Image(systemName: "info.circle") }.help("Show download details").accessibilityLabel("Details for \(job.name)")
            }.buttonStyle(.borderless).font(.system(size: 14)).disabled(store.pending.contains(job.id) || !store.online).padding(.top, 4)
        }.padding(.vertical, 11).accessibilityElement(children: .contain)
    }
    var statusSymbol: String { switch job.status { case "completed": return "checkmark.circle.fill"; case "error": return "exclamationmark.circle"; case "paused": return "pause.circle"; case "queued": return "clock"; case "canceled": return "xmark.circle"; case "processing": return "gearshape.2"; default: return "arrow.down.circle" } }
    var fileSymbol: String {
        if job.type.isMedia { return job.mode == "audio" || job.quality == "audio" ? "music.note" : "film" }
        if job.type == .torrent { return "shippingbox" }
        let ext = (job.name as NSString).pathExtension.lowercased()
        if ["zip", "gz", "dmg", "iso", "7z"].contains(ext) { return "doc.zipper" }
        if ["png", "jpg", "webp", "heic"].contains(ext) { return "photo" }
        return "doc"
    }
    func rowButton(_ title: String, symbol: String, action: String) -> some View {
        Button { Task { await store.action(job, action) } } label: { Image(systemName: symbol) }.help(title).accessibilityLabel("\(title): \(job.name)")
    }
}
struct JobMenu: View {
    @EnvironmentObject var store: AppModel
    let job: DownloadJob
    let remove: () -> Void
    var body: some View {
        if job.canPause { Button("Pause") { Task { await store.action(job, "pause") } }.disabled(!store.online) }
        if job.canResume { Button(job.status == "paused" ? "Resume" : "Retry") { Task { await store.action(job, "resume") } }.disabled(!store.online) }
        if job.status == "completed", let file = job.files.first {
            Button("Show in Finder") { store.reveal(file, job: job) }
            Button("Save a Copy…") { store.saveCopy(file, job: job) }
        }
        Button("Copy Source Link") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(job.source, forType: .string) }
        Button("Show Details") { store.selectedID = job.id; store.showInspector = true }
        Divider()
        if job.canCancel { Button("Cancel Download", role: .destructive) { Task { await store.action(job, "cancel") } }.disabled(!store.online) }
        if job.canRemove { Button("Remove from History…", role: .destructive, action: remove).disabled(!store.online) }
    }
}

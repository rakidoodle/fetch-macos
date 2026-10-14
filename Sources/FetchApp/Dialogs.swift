import SwiftUI
import AppKit
import UniformTypeIdentifiers
import FetchCore

struct AddDownloadView: View {
    @EnvironmentObject var store: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var source: String
    @State private var kind: DownloadKind
    @State private var mode = "video"
    @State private var resolution = "best"
    @State private var format = "mp4"
    @AppStorage("preferredVideoFormat") private var preferredVideoFormat = "mp4"
    @State private var videoInfo: VideoInfo?
    @State private var playerContext: VideoContext?
    @State private var finding = false
    @State private var showPlayer = false
    @State private var detectionTask: Task<Void, Never>?
    @State private var torrentData: String?
    @State private var torrentName: String?
    @State private var error: String?
    @State private var busy = false
    @State private var reading = false
    @FocusState private var sourceFocused: Bool
    init(initialSource: String = "") {
        _source = State(initialValue: initialSource)
        _kind = State(initialValue: DownloadKind.detect(initialSource))
    }
    var request: AddRequest {
        AddRequest(type: kind, source: source.trimmingCharacters(in: .whitespacesAndNewlines), mode: kind.isMedia ? mode : nil, resolution: kind.isMedia ? resolution : nil, format: kind.isMedia ? format : nil, torrent: kind == .torrent ? torrentData : nil, name: torrentName, context: kind == .video ? playerContext : nil)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("New download").font(.system(size: 24, weight: .semibold))
                    Text("A link is all you need.").font(.system(size: 13)).foregroundStyle(Color(nsColor: NativePalette.secondary))
                }
                Spacer()
                Image(systemName: "arrow.down.circle").font(.system(size: 32, weight: .light)).foregroundStyle(.tint).accessibilityHidden(true)
            }
            Picker("Download type", selection: $kind) { ForEach(DownloadKind.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(kind == .torrent ? "Magnet link or torrent URL" : kind.isMedia ? "Video page or stream URL" : "File URL").font(.system(size: 13, weight: .medium))
                    Spacer()
                    Button("Paste Link") {
                        if let value = NSPasteboard.general.string(forType: .string) { source = value; let detected = DownloadKind.detect(value); if kind != .video || detected != .web { kind = detected }; torrentData = nil; torrentName = nil }
                    }.buttonStyle(.link).disabled(busy)
                }
                TextField(kind == .torrent ? "magnet:?xt=urn:btih:…" : "https://…", text: $source, axis: .vertical)
                    .lineLimit(2...4).textFieldStyle(.roundedBorder).focused($sourceFocused).disabled(torrentData != nil || busy)
                    .accessibilityLabel(kind.isMedia ? "Video page or stream URL" : kind == .torrent ? "Magnet link or torrent URL" : "File URL")
                Text(kind == .web ? "Direct HTTP or HTTPS links. Parallel connections are used when the server supports them." : kind.isMedia ? "Choose a video page or direct stream. Select your preferred output format below." : "Paste a magnet link, use a .torrent URL, or choose a file.")
                    .font(.system(size: 12)).foregroundStyle(Color(nsColor: NativePalette.secondary)).fixedSize(horizontal: false, vertical: true)
            }
            if kind == .torrent {
                HStack {
                    Button { Task { await chooseTorrent() } } label: { Label("Choose Torrent File…", systemImage: "doc.badge.plus") }.disabled(busy || reading)
                    if reading { ProgressView().controlSize(.small) }
                    if let torrentName { Text(torrentName).font(.callout).lineLimit(1); Button("Clear") { torrentData = nil; self.torrentName = nil }.buttonStyle(.link) }
                }
            }
            if kind == .video {
                HStack {
                    Button { detectionTask = Task { await findVideo() } } label: { Label(finding ? "Finding video…" : "Find Video", systemImage: "magnifyingglass") }.disabled(busy || finding || request.validationError != nil)
                    if finding { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Open Player…") { showPlayer = true }.disabled(busy || finding || request.validationError != nil)
                }
                if let videoInfo { Label(videoInfo.title, systemImage: "checkmark.circle").font(.callout).lineLimit(2) }
                if playerContext != nil { Label("Player stream selected. Session stays private.", systemImage: "checkmark.circle").font(.callout) }
            }
            if kind.isMedia {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("Media", selection: $mode) { Text("Video").tag("video"); Text("Audio only").tag("audio") }.pickerStyle(.segmented)
                    HStack(spacing: 24) {
                        if mode == "video" {
                            Picker("Resolution", selection: $resolution) {
                                Text("Best available").tag("best")
                                ForEach(kind == .video && (videoInfo?.resolutions.isEmpty ?? true) ? [] : ["2160", "1440", "1080", "720", "480", "360", "240", "144"], id: \.self) { Text($0 + "p").tag($0) }
                            }
                        }
                        Picker("Format", selection: $format) {
                            ForEach(mode == "video" ? ["original", "mp4", "webm", "mkv", "mov"] : ["mp3", "m4a", "flac", "wav", "opus"], id: \.self) { Text($0 == "original" ? "Original (fastest)" : $0.uppercased()).tag($0) }
                        }
                    }
                    Text(mode == "video" ? "MP4 suits most players. WebM may need conversion; MKV and MOV are also available. Original keeps the source format." : "Audio is extracted and converted with FFmpeg.").font(.system(size: 12)).foregroundStyle(Color(nsColor: NativePalette.secondary))
                }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.circle").font(.system(size: 12)).foregroundStyle(Color(nsColor: NativePalette.error)).fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Error: \(error)")
            }
            Divider()
            HStack {
                Label("Saved in Downloads/Fetch", systemImage: "folder").font(.system(size: 11)).foregroundStyle(Color(nsColor: NativePalette.secondary))
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
                Button { Task { await submit() } } label: {
                    if busy { ProgressView().controlSize(.small).frame(width: 110) } else { Text("Add Download").frame(minWidth: 100) }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(busy || finding || reading || !store.online || (kind == .video && videoInfo == nil && playerContext == nil))
            }
        }.padding(28).frame(width: 570)
            .onAppear { sourceFocused = true; format = preferredVideoFormat }
            .onDisappear { detectionTask?.cancel() }
            .sheet(isPresented: $showPlayer) {
                if let page = URL(string: source.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    VideoBrowserView(page: page) { context in playerContext = context; videoInfo = nil; resolution = "best"; error = nil }
                }
            }
            .onChange(of: source) { _, value in
                videoInfo = nil; playerContext = nil; error = nil
                if !value.isEmpty, torrentData == nil { let detected = DownloadKind.detect(value); if detected != .web { kind = detected } }
            }
            .onChange(of: mode) { _, value in format = value == "audio" ? "mp3" : preferredVideoFormat }
            .onChange(of: format) { _, value in if mode == "video", ["original", "mp4", "webm", "mkv", "mov"].contains(value) { preferredVideoFormat = value } }
            .onChange(of: kind) { _, value in videoInfo = nil; playerContext = nil; detectionTask?.cancel(); if value != .torrent { torrentData = nil; torrentName = nil }; error = nil }
    }
    func findVideo() async {
        finding = true; error = nil
        let value = source.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { finding = false }
        do {
            let info = try await store.analyzeVideo(value)
            guard !Task.isCancelled, source.trimmingCharacters(in: .whitespacesAndNewlines) == value, kind == .video else { return }
            videoInfo = info; playerContext = nil; resolution = "best"
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
    func submit() async {
        error = request.validationError
        guard error == nil else { sourceFocused = true; return }
        busy = true
        defer { busy = false }
        do { try await store.add(request); dismiss() } catch { self.error = error.localizedDescription }
    }
    func chooseTorrent() async {
        reading = true; error = nil
        defer { reading = false }
        do {
            if let (name, data) = try await store.importTorrent() { torrentName = name; torrentData = data; source = "" }
        } catch { self.error = error.localizedDescription }
    }
}
struct PreferencesView: View {
    @EnvironmentObject var store: AppModel
    @State private var settings = TransferSettings()
    @AppStorage("preferredVideoFormat") private var preferredVideoFormat = "mp4"
    @State private var saving = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                if let icon = NSImage(contentsOf: store.resources.appendingPathComponent("app-icon.png")) { Image(nsImage: icon).resizable().frame(width: 48, height: 48).accessibilityHidden(true) }
                VStack(alignment: .leading, spacing: 4) { Text("Fetch Settings").font(.title2.weight(.semibold)); Text("Designed for your Mac.").font(.callout).foregroundStyle(Color(nsColor: NativePalette.secondary)) }
            }
            Form {
                Section("Transfers") {
                    Stepper("Connections per download: \(settings.connections)", value: $settings.connections, in: 1...16)
                    Stepper("Active downloads: \(settings.maxActive)", value: $settings.maxActive, in: 1...8)
                    HStack { Text("Speed limit (KiB/s)"); Spacer(); TextField("0", value: $settings.speedLimit, format: .number.grouping(.never)).frame(width: 110).textFieldStyle(.roundedBorder).accessibilityLabel("Speed limit in KiB per second") }
                    if !settings.isValid { Text("Use 1–16 connections, 1–8 active downloads, and a speed limit from 0–1,000,000 KiB/s.").font(.caption).foregroundStyle(Color(nsColor: NativePalette.error)) }
                    Text("0 means unlimited. Queue limits apply to all sources. Speed limits apply to new video downloads and all file/torrent transfers.").font(.caption).foregroundStyle(Color(nsColor: NativePalette.secondary))
                }
                Section("Video output") {
                    Picker("Default video format", selection: $preferredVideoFormat) {
                        ForEach(["original", "mp4", "webm", "mkv", "mov"], id: \.self) { Text($0 == "original" ? "Original (fastest)" : $0.uppercased()).tag($0) }
                    }
                }
                Section("On your Mac") {
                    LabeledContent("Appearance", value: "Follow system")
                    HStack { Text("Download folder"); Spacer(); Button("Show in Finder") { store.openDownloads() } }
                    Text(store.downloadDir.path).font(.caption).foregroundStyle(Color(nsColor: NativePalette.secondary)).textSelection(.enabled)
                    Text("Quitting pauses unfinished downloads. Reopen Fetch and resume them when you are ready.").font(.caption).foregroundStyle(Color(nsColor: NativePalette.secondary))
                }
                Section("Engines") {
                    engine("Files & torrents", ready: store.state?.engines.aria2 ?? false)
                    engine("Web videos & YouTube", ready: store.state?.engines.youtube ?? false)
                    engine("Media conversion", ready: store.state?.engines.ffmpeg ?? false)
                    Button("Restart Download Service") { Task { await store.restart() } }.disabled(store.starting || saving)
                }
            }.formStyle(.grouped)
            if let error { Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(Color(nsColor: NativePalette.error)) }
            HStack {
                Link("Feed my Baby", destination: URL(string: "https://www.paypal.com/paypalme/ruffytrinidad")!)
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button("Save Changes") { Task { await save() } }.buttonStyle(.borderedProminent).disabled(saving || !store.online || !settings.isValid)
            }
        }.padding(24).frame(width: 540, height: 690)
        .onAppear { if let value = store.state?.settings { settings = value } }
    }
    func engine(_ name: String, ready: Bool) -> some View {
        LabeledContent(name) { Label(ready ? "Ready" : "Unavailable", systemImage: ready ? "checkmark.circle" : "exclamationmark.triangle").foregroundStyle(ready ? Color(nsColor: NativePalette.secondary) : Color.orange) }
    }
    func save() async {
        saving = true; error = nil
        defer { saving = false }
        do { try await store.updateSettings(settings) } catch { self.error = error.localizedDescription }
    }
}

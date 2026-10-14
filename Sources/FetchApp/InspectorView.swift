import SwiftUI
import AppKit
import FetchCore

struct InspectorView: View {
    @EnvironmentObject var store: AppModel
    let job: DownloadJob
    let remove: () -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    Text("Download details").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button { store.showInspector = false } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("Close inspector").accessibilityLabel("Close inspector")
                }
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: job.type.symbol).font(.system(size: 28, weight: .light)).foregroundStyle(.tint).accessibilityHidden(true)
                    Text(job.name).font(.system(size: 16, weight: .semibold)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    Label(job.statusTitle, systemImage: job.status == "completed" ? "checkmark.circle" : job.status == "error" ? "exclamationmark.circle" : "arrow.down.circle").font(.callout).foregroundStyle(job.status == "error" ? Color(nsColor: NativePalette.error) : Color(nsColor: NativePalette.secondary))
                }
                if let error = job.error, job.status == "error" {
                    Text(error).font(.callout).foregroundStyle(Color(nsColor: NativePalette.error)).textSelection(.enabled)
                    Button("Retry Download") { Task { await store.action(job, "resume") } }.disabled(!store.online || store.pending.contains(job.id))
                }
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    item("Type", value: job.type.title)
                    if job.type.isMedia {
                        item("Media", value: job.mode == "audio" || job.quality == "audio" ? "Audio only" : "Video")
                        if job.mode != "audio", job.quality != "audio" {
                            let cap = job.resolution ?? job.quality ?? "best"
                            item("Resolution", value: cap == "best" ? "Best available" : cap + "p maximum")
                        }
                        if let format = job.format { item("Format", value: format.uppercased()) }
                    }
                    item("Size", value: job.total > 0 ? DisplayFormat.bytes(job.total) : "Not known yet")
                    item("Downloaded", value: DisplayFormat.bytes(job.completed))
                    item("Connections", value: "\(job.connections)")
                    if job.type == .torrent { item("Seeders", value: "\(job.seeders ?? 0)") }
                    item("Added", value: Date(timeIntervalSince1970: job.created / 1000).formatted(date: .abbreviated, time: .shortened))
                }
                if !job.segments.isEmpty {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("Transfer segments").font(.system(size: 12, weight: .medium))
                        HStack(spacing: 3) {
                            ForEach(Array(job.segments.enumerated()), id: \.offset) { _, progress in
                                RoundedRectangle(cornerRadius: 2).fill(Color.accentColor.opacity(0.15 + 0.85 * progress)).frame(height: 24)
                            }
                        }.accessibilityElement(children: .ignore).accessibilityLabel("Segment completion").accessibilityValue("\(Int(job.progress * 100)) percent")
                        Text("Parallel parts are verified by the download engine.").font(.caption).foregroundStyle(Color(nsColor: NativePalette.secondary))
                    }
                }
                VStack(alignment: .leading, spacing: 9) {
                    Text("Source").font(.system(size: 12, weight: .medium))
                    Text(job.source).font(.system(size: 12)).foregroundStyle(Color(nsColor: NativePalette.secondary)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Button("Copy Link") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(job.source, forType: .string); store.notify("Source link copied.") }.buttonStyle(.link)
                }
                if job.status == "completed" {
                    Divider()
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Files").font(.system(size: 12, weight: .medium))
                        ForEach(job.files) { file in
                            VStack(alignment: .leading, spacing: 6) {
                                Label(file.name, systemImage: "doc").font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                                HStack { Button("Show in Finder") { store.reveal(file, job: job) }; Button("Save Copy…") { store.saveCopy(file, job: job) } }.font(.system(size: 11))
                            }
                        }
                    }
                }
                let events = Array((store.state?.events ?? []).filter { $0.jobId == job.id }.prefix(5))
                if !events.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 11) {
                        Text("Activity").font(.system(size: 12, weight: .medium))
                        ForEach(events) { event in
                            HStack { Text(event.verb.capitalized); Spacer(); Text(Date(timeIntervalSince1970: event.time / 1000), style: .time) }.font(.system(size: 11)).foregroundStyle(Color(nsColor: NativePalette.secondary))
                        }
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    if job.canCancel { Button("Cancel Download", role: .destructive) { Task { await store.action(job, "cancel") } }.disabled(!store.online) }
                    if job.canRemove { Button("Remove from History…", role: .destructive, action: remove).disabled(!store.online) }
                    Text("Files are never deleted by these controls.").font(.caption).foregroundStyle(Color(nsColor: NativePalette.secondary))
                }
            }.padding(20)
        }.background(Color(nsColor: .controlBackgroundColor))
    }
    func item(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) { Text(title).foregroundStyle(Color(nsColor: NativePalette.secondary)); Spacer(minLength: 8); Text(value).multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) }.font(.system(size: 12))
    }
}

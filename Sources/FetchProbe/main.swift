import Foundation
import FetchCore

@main struct FetchProbe {
    static func main() async {
        do {
            let args = CommandLine.arguments
            guard args.count >= 3 else { throw ServiceError.message("Usage: FetchProbe <app resources> <fixture base URL> [torrent file] [magnet]") }
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("fetch-native-probe-" + UUID().uuidString)
            let data = temp.appendingPathComponent("state"), downloads = temp.appendingPathComponent("downloads")
            let bridge = BackendBridge()
            do {
                let client = try await bridge.start(resources: URL(fileURLWithPath: args[1]), dataDir: data, downloadDir: downloads)
                let initial = try await client.state()
                guard initial.engines.allReady else { throw ServiceError.message("A bundled engine is unavailable.") }
                print("PASS: native bootstrap, authenticated API, all bundled engines")
                let prefs = TransferSettings(connections: 4, maxActive: 1, speedLimit: 512)
                try await client.settings(prefs)
                let saved = try await client.state()
                guard saved.settings == prefs else { throw ServiceError.message("Settings did not persist.") }
                print("PASS: native transfer settings")
                let id = try await client.add(AddRequest(type: .web, source: args[2] + "/file.bin"))
                var job = try await wait(client, id: id) { $0.completed > 0 || $0.status == "error" }
                guard job.status != "error" else { throw ServiceError.message(job.error ?? "Web download failed") }
                try await client.action(id, "pause")
                let paused = try await client.state().jobs.first { $0.id == id }
                guard paused?.status == "paused" else { throw ServiceError.message("Pause failed.") }
                try await Task.sleep(nanoseconds: 350_000_000)
                let still = try await client.state().jobs.first { $0.id == id }
                guard still?.completed == paused?.completed else { throw ServiceError.message("Paused transfer moved.") }
                print("PASS: native download pause")
                await bridge.stop()
                let restarted = try await bridge.start(resources: URL(fileURLWithPath: args[1]), dataDir: data, downloadDir: downloads)
                let restored = try await restarted.state()
                guard restored.jobs.first(where: { $0.id == id })?.status == "paused", restored.settings == prefs else { throw ServiceError.message("Restart recovery failed.") }
                try await restarted.settings(TransferSettings(connections: 8, maxActive: 3, speedLimit: 0))
                try await restarted.action(id, "resume")
                job = try await wait(restarted, id: id) { ["completed", "error"].contains($0.status) }
                guard job.status == "completed", let file = job.files.first else { throw ServiceError.message(job.error ?? "No completed file.") }
                let actual = try Data(contentsOf: DisplayFormat.safeFile(file, job: job, downloadDir: downloads.path))
                let (expected, _) = try await URLSession.shared.data(from: URL(string: args[2] + "/file.bin")!)
                guard actual == expected else { throw ServiceError.message("Downloaded bytes differ from fixture.") }
                print("PASS: native restart, resume, completed file bytes, safe file access")
                if args.count >= 5 {
                    let torrent = try Data(contentsOf: URL(fileURLWithPath: args[3])).base64EncodedString()
                    let torrentID = try await restarted.add(AddRequest(type: .torrent, source: "", torrent: torrent, name: "fixture.torrent"))
                    let torrentJob = try await wait(restarted, id: torrentID) { ["completed", "error"].contains($0.status) }
                    guard torrentJob.status == "completed", let torrentFile = torrentJob.files.first,
                          try Data(contentsOf: DisplayFormat.safeFile(torrentFile, job: torrentJob, downloadDir: downloads.path)) == expected else { throw ServiceError.message(torrentJob.error ?? "Torrent bytes differ.") }
                    let magnetID = try await restarted.add(AddRequest(type: .torrent, source: args[4]))
                    let magnetJob = try await wait(restarted, id: magnetID) { ["completed", "error"].contains($0.status) }
                    guard magnetJob.status == "completed", let magnetFile = magnetJob.files.first,
                          try Data(contentsOf: DisplayFormat.safeFile(magnetFile, job: magnetJob, downloadDir: downloads.path)) == expected else { throw ServiceError.message(magnetJob.error ?? "Magnet bytes differ.") }
                    print("PASS: native torrent upload, magnet metadata, verified torrent payloads")
                }
                try await restarted.action(id, "remove")
                guard FileManager.default.fileExists(atPath: file.path) else { throw ServiceError.message("History removal deleted the file.") }
                print("PASS: native history removal preserves files")
                await bridge.stop()
                try FileManager.default.removeItem(at: temp)
                print("PASS: native service shutdown")
            } catch { await bridge.stop(); try? FileManager.default.removeItem(at: temp); throw error }
        } catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    static func wait(_ client: ServiceClient, id: String, condition: (DownloadJob) -> Bool) async throws -> DownloadJob {
        for _ in 0..<1200 {
            let state = try await client.state()
            guard let job = state.jobs.first(where: { $0.id == id }) else { throw ServiceError.message("Download disappeared.") }
            if condition(job) { return job }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw ServiceError.message("Native transfer timed out.")
    }
}

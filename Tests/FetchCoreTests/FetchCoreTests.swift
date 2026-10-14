import Testing
import Foundation
import AppKit
@testable import FetchCore

struct FetchCoreTests {
    func job(id: String = UUID().uuidString, type: String = "web", status: String = "downloading", name: String = "archive.zip", total: Double = 100, completed: Double = 30, created: Double = 1000, path: String = "/tmp/file") throws -> DownloadJob {
        let object: [String: Any] = ["id": id, "type": type, "source": "https://example.com/archive.zip", "name": name, "status": status, "created": created, "total": total, "completed": completed, "speed": 10, "connections": 4, "segments": [0.0, 1.0], "files": [["name": name, "path": path]], "error": NSNull()]
        return try JSONDecoder().decode(DownloadJob.self, from: JSONSerialization.data(withJSONObject: object))
    }
    @Test func testSourceDetectionMatchesRealHosts() {
        expectEqual(DownloadKind.detect(" HTTPS://WWW.YOUTUBE.COM/watch?v=123 "), .youtube)
        expectEqual(DownloadKind.detect("https://youtube.com.evil.test/watch?v=123"), .web)
        expectEqual(DownloadKind.detect("magnet:?xt=urn:btih:abc"), .torrent)
        expectEqual(DownloadKind.detect("https://example.com/file.TORRENT?key=123"), .torrent)
        expectEqual(DownloadKind.detect("https://example.com/video.mp4"), .web)
    }
    @Test func testValidationRejectsUnsupportedAndCredentialSources() {
        for source in ["", "garbage", "file:///etc/passwd", "ftp://example.com/a", "https://user:pass@example.com/a"] {
            expectNotNil(AddRequest(type: .web, source: source).validationError, source)
        }
        expectNotNil(AddRequest(type: .youtube, source: "https://youtube.com.evil.test/v").validationError)
        expectNotNil(AddRequest(type: .torrent, source: "magnet:?xt=urn:btih:abc").validationError)
        expectNotNil(AddRequest(type: .torrent, source: "https://example.com/video").validationError)
        expectNil(AddRequest(type: .web, source: "https://example.com/file").validationError)
        expectNil(AddRequest(type: .torrent, source: "magnet:?xt=urn:btih:" + String(repeating: "a", count: 40)).validationError)
        expectNil(AddRequest(type: .torrent, source: "", torrent: "ZGU=").validationError)
    }
    @Test func testIndependentYouTubeResolutionAndFormatEncoding() throws {
        let request = AddRequest(type: .youtube, source: "https://youtu.be/video", mode: "video", resolution: "1080", format: "webm")
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as! [String: String]
        expectEqual(object["resolution"], "1080")
        expectEqual(object["format"], "webm")
        expectEqual(object["mode"], "video")
        expectNil(object["torrent"])
    }
    @Test func testYouTubeMetadataSurvivesNativeDecoding() throws {
        let baseline = try job(type: "youtube")
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(baseline)) as! [String: Any]
        object["mode"] = "audio"; object["resolution"] = "best"; object["format"] = "flac"; object["quality"] = "audio"
        let decoded = try JSONDecoder().decode(DownloadJob.self, from: JSONSerialization.data(withJSONObject: object))
        expectEqual(decoded.mode, "audio"); expectEqual(decoded.format, "flac")
        expectEqual(decoded.resolution, "best"); expectEqual(decoded.quality, "audio")
    }
    @Test func testSettingsBounds() {
        expectTrue(TransferSettings().isValid)
        expectTrue(TransferSettings(connections: 16, maxActive: 8, speedLimit: 1_000_000).isValid)
        for settings in [TransferSettings(connections: 0), TransferSettings(connections: 17), TransferSettings(maxActive: 0), TransferSettings(maxActive: 9), TransferSettings(speedLimit: -1), TransferSettings(speedLimit: 1_000_001)] { expectFalse(settings.isValid) }
    }
    @Test func testStateActionsRespectLifecycle() throws {
        let active = try job(); expectTrue(active.canPause); expectFalse(active.canResume); expectFalse(active.canRemove)
        let processing = try job(status: "processing"); expectTrue(processing.canPause); expectFalse(processing.canRemove)
        let queued = try job(status: "queued"); expectTrue(queued.canPause); expectFalse(queued.canRemove)
        let paused = try job(status: "paused"); expectTrue(paused.canResume); expectTrue(paused.canRemove)
        let completed = try job(status: "completed"); expectFalse(completed.canCancel); expectTrue(completed.canRemove)
        let failed = try job(status: "error"); expectTrue(failed.canResume); expectEqual(failed.statusTitle, "Needs attention")
    }
    @Test func testLibraryFiltersAndSort() throws {
        let a = try job(type: "web", status: "completed", name: "Zebra", total: 100, created: 1000)
        let b = try job(type: "youtube", status: "paused", name: "Apple", total: 200, created: 2000)
        let c = try job(type: "torrent", status: "error", name: "Map", total: 50, created: 3000)
        expectTrue(LibrarySection.completed.includes(a)); expectFalse(LibrarySection.active.includes(a))
        expectTrue(LibrarySection.youtube.includes(b)); expectTrue(LibrarySection.paused.includes(b))
        expectTrue(LibrarySection.attention.includes(c)); expectTrue(LibrarySection.torrent.includes(c))
        expectEqual(DownloadSort.newest.sorted([a,b,c]).map(\.id), [c.id,b.id,a.id])
        expectEqual(DownloadSort.oldest.sorted([a,b,c]).map(\.id), [a.id,b.id,c.id])
        expectEqual(DownloadSort.name.sorted([a,b,c]).map(\.id), [b.id,c.id,a.id])
        expectEqual(DownloadSort.size.sorted([a,b,c]).map(\.id), [b.id,a.id,c.id])
    }
    @Test func testProgressAndFormattingHandleUnknownValues() throws {
        expectEqual(try job(total: 0, completed: 100).progress, 0)
        expectEqual(try job(total: 100, completed: 200).progress, 1)
        expectEqual(try job(total: 100, completed: -5).progress, 0)
        expectEqual(DisplayFormat.bytes(.infinity), "0 B")
        expectEqual(DisplayFormat.bytes(-1), "0 B")
        expectEqual(DisplayFormat.eta(0), "Estimating…")
        expectEqual(DisplayFormat.eta(59), "59s remaining")
        expectEqual(DisplayFormat.eta(61), "2m remaining")
    }
    @Test @MainActor func testNativeThemeTextContrast() throws {
        func luminance(_ r: Double, _ g: Double, _ b: Double) -> Double {
            func linear(_ value: Double) -> Double { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
            return linear(r) * 0.2126 + linear(g) * 0.7152 + linear(b) * 0.0722
        }
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            appearance.performAsCurrentDrawingAppearance {
                for background in [NSColor.controlBackgroundColor, .windowBackgroundColor] {
                    let bg = background.usingColorSpace(.sRGB)!
                    let back = luminance(bg.redComponent, bg.greenComponent, bg.blueComponent)
                    for foreground in [NativePalette.secondary, NativePalette.error] {
                        let fg = foreground.usingColorSpace(.sRGB)!
                        let alpha = fg.alphaComponent
                        let front = luminance(fg.redComponent * alpha + bg.redComponent * (1-alpha), fg.greenComponent * alpha + bg.greenComponent * (1-alpha), fg.blueComponent * alpha + bg.blueComponent * (1-alpha))
                        let contrast = (max(front, back) + 0.05) / (min(front, back) + 0.05)
                        #expect(contrast >= 4.5, "Native light/dark text contrast must meet 4.5:1")
                    }
                }
            }
        }
    }
    @Test func testAtomicExportPreservesExistingFileOnFailure() async throws {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("FetchExport-" + UUID().uuidString)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }
        let source = temp.appendingPathComponent("source"), target = temp.appendingPathComponent("target")
        try Data("new bytes".utf8).write(to: source); try Data("old bytes".utf8).write(to: target)
        try await FileExporter.copy(source: source, destination: target)
        expectEqual(try Data(contentsOf: source), Data("new bytes".utf8))
        expectEqual(try Data(contentsOf: target), Data("new bytes".utf8))
        do { try await FileExporter.copy(source: temp.appendingPathComponent("missing"), destination: target); Issue.record("Missing source should fail") } catch {}
        expectEqual(try Data(contentsOf: target), Data("new bytes".utf8))
        do { try await FileExporter.copy(source: source, destination: source); Issue.record("Same source and destination should fail") } catch {}
        expectEqual(try Data(contentsOf: source), Data("new bytes".utf8))
        expectEqual(try fm.contentsOfDirectory(atPath: temp.path).sorted(), ["source", "target"])
    }
    @Test func testFileContainmentRejectsSymlinksAndMovedFiles() throws {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("FetchContainment-" + UUID().uuidString)
        defer { try? fm.removeItem(at: temp) }
        let id = UUID().uuidString
        let root = temp.appendingPathComponent(id)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let inside = root.appendingPathComponent("file.zip")
        let outside = temp.appendingPathComponent("secret")
        try Data("safe".utf8).write(to: inside); try Data("private".utf8).write(to: outside)
        let j = try job(id: id, status: "completed", path: inside.path)
        expectEqual(try DisplayFormat.safeFile(j.files[0], job: j, downloadDir: temp.path), inside.resolvingSymlinksInPath())
        let link = root.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: outside)
        let escaped = try job(id: id, status: "completed", path: link.path)
        expectThrows(try DisplayFormat.safeFile(escaped.files[0], job: escaped, downloadDir: temp.path))
        try fm.removeItem(at: inside)
        expectThrows(try DisplayFormat.safeFile(j.files[0], job: j, downloadDir: temp.path))
    }
}

private func expectEqual<T: Equatable>(_ lhs: T, _ rhs: T) { #expect(lhs == rhs) }
private func expectTrue(_ value: Bool) { #expect(value) }
private func expectFalse(_ value: Bool) { #expect(!value) }
private func expectNil<T>(_ value: T?) { #expect(value == nil) }
private func expectNotNil<T>(_ value: T?, _ message: String = "") { #expect(value != nil, Comment(rawValue: message)) }
private func expectThrows<T>(_ expression: @autoclosure () throws -> T) {
    do { _ = try expression(); Issue.record("Expected the operation to throw") } catch {}
}

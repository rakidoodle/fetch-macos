import Foundation

public actor BackendBridge {
    private var process: Process?
    private var temporary: URL?
    private var logHandle: FileHandle?
    public init() {}
    public func start(resources: URL, dataDir: URL, downloadDir: URL) async throws -> ServiceClient {
        guard process == nil else { throw ServiceError.message("Download service is already running.") }
        let fm = FileManager.default
        try fm.createDirectory(at: dataDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: downloadDir, withIntermediateDirectories: true)
        let logs = dataDir.appendingPathComponent("logs", isDirectory: true)
        try fm.createDirectory(at: logs, withIntermediateDirectories: true)
        let temp = fm.temporaryDirectory.appendingPathComponent("Fetch-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        temporary = temp
        let readyFile = temp.appendingPathComponent("ready.json")
        let logURL = logs.appendingPathComponent("service.log")
        fm.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let output = try FileHandle(forWritingTo: logURL)
        logHandle = output
        let token = UUID().uuidString + UUID().uuidString
        let bin = resources.appendingPathComponent("Runtime/bin", isDirectory: true)
        let node = bin.appendingPathComponent("node")
        let native = resources.appendingPathComponent("backend/server/native.js")
        guard fm.isExecutableFile(atPath: node.path), fm.fileExists(atPath: native.path) else { throw ServiceError.message("The app bundle is incomplete. Rebuild or reinstall Fetch.") }
        let child = Process()
        child.executableURL = node
        child.arguments = [native.path]
        child.currentDirectoryURL = dataDir
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = bin.path + ":/usr/bin:/bin:/usr/sbin:/sbin"
        env["NODE_ENV"] = "production"
        env["FETCH_NATIVE_TOKEN"] = token
        env["FETCH_DATA_DIR"] = dataDir.path
        env["FETCH_DOWNLOAD_DIR"] = downloadDir.path
        env["FETCH_READY_FILE"] = readyFile.path
        env["FETCH_PARENT_PID"] = String(ProcessInfo.processInfo.processIdentifier)
        env["ARIA2_BIN"] = bin.appendingPathComponent("aria2c").path
        env["YTDLP_BIN"] = bin.appendingPathComponent("yt-dlp").path
        child.environment = env
        child.standardOutput = output
        child.standardError = output
        do { try child.run(); process = child } catch { await stop(); throw error }
        for _ in 0..<250 {
            if Task.isCancelled { await stop(); throw CancellationError() }
            if !child.isRunning {
                let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
                await stop()
                throw ServiceError.message("Download service did not start. \(String(log.suffix(1200)))")
            }
            if let data = try? Data(contentsOf: readyFile) {
                struct Ready: Decodable { let port: Int }
                if let ready = try? JSONDecoder().decode(Ready.self, from: data), (1...65535).contains(ready.port) {
                    let client = ServiceClient(port: ready.port, token: token)
                    do { _ = try await client.state(); return client } catch { await stop(); throw error }
                }
            }
            do { try await Task.sleep(nanoseconds: 100_000_000) } catch { await stop(); throw error }
        }
        await stop()
        throw ServiceError.message("Download service took too long to start. Check the service log, then retry.")
    }
    public func stop() async {
        if let child = process, child.isRunning {
            child.terminate()
            for _ in 0..<70 {
                if !child.isRunning { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
        }
        process = nil
        try? logHandle?.close()
        logHandle = nil
        if let temporary { try? FileManager.default.removeItem(at: temporary) }
        temporary = nil
    }
    public var isRunning: Bool { process?.isRunning ?? false }
}

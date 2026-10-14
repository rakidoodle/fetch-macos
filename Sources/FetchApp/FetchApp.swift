import SwiftUI
import AppKit
import FetchCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var terminating = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Test-only app appearance overrides do not change the Mac's global appearance.
        if let mode = ProcessInfo.processInfo.environment["FETCH_TEST_APPEARANCE"] {
            NSApp.appearance = NSAppearance(named: mode == "dark" ? .darkAqua : .aqua)
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminating { return .terminateLater }
        terminating = true
        Task { @MainActor in
            await AppModel.shared.stop()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { NSApp.windows.first(where: { $0.canBecomeMain && $0.title != "Fetch Settings" })?.makeKeyAndOrderFront(nil) }
        return true
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        if let value = urls.first, value.scheme == "magnet" {
            NotificationCenter.default.post(name: .fetchIncomingURL, object: value.absoluteString)
        }
    }
}
extension Notification.Name {
    static let fetchSearch = Notification.Name("fetch.search")
    static let fetchIncomingURL = Notification.Name("fetch.incoming")
}
@main struct FetchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = AppModel.shared
    var body: some Scene {
        Window("Fetch", id: "main") {
            MainView().environmentObject(store).task { await store.start() }
        }
        .defaultSize(width: 1120, height: 720)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Download…") { store.showAdd = true }.keyboardShortcut("n").disabled(!store.online)
            }
            CommandGroup(after: .sidebar) {
                Button(store.showInspector ? "Hide Inspector" : "Show Inspector") { store.showInspector.toggle() }.keyboardShortcut("i", modifiers: [.command, .option])
                Button("Search Downloads") { NotificationCenter.default.post(name: .fetchSearch, object: nil) }.keyboardShortcut("f")
            }
            CommandMenu("Downloads") {
                Button("Pause Selected Download") { if let job = store.selected { Task { await store.action(job, "pause") } } }
                    .keyboardShortcut("p", modifiers: [.command, .option]).disabled(!store.online || !(store.selected?.canPause ?? false))
                Button("Resume or Retry Selected Download") { if let job = store.selected { Task { await store.action(job, "resume") } } }
                    .keyboardShortcut("r", modifiers: [.command, .option]).disabled(!store.online || !(store.selected?.canResume ?? false))
                Button("Cancel Selected Download") { if let job = store.selected { Task { await store.action(job, "cancel") } } }
                    .disabled(!store.online || !(store.selected?.canCancel ?? false))
                Divider()
                Button("Pause All") { Task { await store.bulk("pause") } }.disabled(!store.online || !store.jobs.contains(where: \.canPause))
                Button("Resume Paused") { Task { await store.bulk("resume") } }.disabled(!store.online || !store.jobs.contains(where: { $0.status == "paused" }))
                Divider()
                Button("Show Downloads in Finder") { store.openDownloads() }.keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .help) {
                Button("Fetch Help") { NSWorkspace.shared.open(Bundle.main.resourceURL!.appendingPathComponent("Help.html")) }
                Button("Feed my Baby") { NSWorkspace.shared.open(URL(string: "https://www.paypal.com/paypalme/ruffytrinidad")!) }
            }
        }
        Settings { PreferencesView().environmentObject(store) }
    }
}

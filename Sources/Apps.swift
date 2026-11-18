import AppKit
import ApplicationServices

/// A notification badge in the Dock (the red "3" on Mail or Spark).
struct AppBadge: Equatable {
    let bundleID: String
    let url: URL
    let label: String
    /// A badge without a number (a dot, "!") counts as one.
    var count: Int { Int(label) ?? 1 }
}

/// A regular app (one with a Dock icon) that is running.
struct RunningApp {
    let name: String
    let bundleID: String?
    let url: URL?
    let icon: NSImage?
    let windows: Int
}

/// Running apps and their notification badges. macOS has no public API for another app's
/// badge, but the Dock, even hidden, exposes each one through Accessibility (AXStatusLabel).
enum Apps {
    private static var idForPath: [String: String] = [:]
    private static let lock = NSLock()

    /// The badges the Dock shows now, in Dock order. Any thread but the main one.
    static func badges() -> [AppBadge] {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return [] }
        let dockElement = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(dockElement, 0.5)
        var found: [AppBadge] = []
        for list in children(of: dockElement) where value(list, kAXRoleAttribute) as? String == kAXListRole {
            for item in children(of: list) {
                guard let label = value(item, "AXStatusLabel") as? String, !label.isEmpty,
                      let url = value(item, kAXURLAttribute) as? URL,
                      let id = bundleID(for: url), !found.contains(where: { $0.bundleID == id }) else { continue }
                found.append(AppBadge(bundleID: id, url: url, label: label))
            }
        }
        return found
    }

    /// The regular running apps, by name, with their standard windows counted (Accessibility
    /// sees those of the current Space, and minimized ones). Any thread but the main one.
    static func running() -> [RunningApp] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() }
            .map { RunningApp(name: $0.localizedName ?? $0.bundleIdentifier ?? "?", bundleID: $0.bundleIdentifier,
                              url: $0.bundleURL, icon: $0.icon, windows: standardWindowCount(of: $0.processIdentifier)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Brings the app to the front, as a click in the Dock does. Works from a background app,
    /// unlike NSRunningApplication.activate() on recent macOS.
    static func open(_ url: URL) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
            if let error { log("open \(url.lastPathComponent): \(error.localizedDescription)") }
        }
    }

    private static func standardWindowCount(of pid: pid_t) -> Int {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        let windows = (value(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        return windows.filter { value($0, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole }.count
    }

    private static func bundleID(for url: URL) -> String? {
        lock.lock(); defer { lock.unlock() }
        if let id = idForPath[url.path] { return id }
        let id = Bundle(url: url)?.bundleIdentifier
        if let id { idForPath[url.path] = id }
        return id
    }

    private static func value(_ e: AXUIElement, _ attr: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(e, attr as CFString, &v) == .success ? v : nil
    }

    private static func children(of e: AXUIElement) -> [AXUIElement] {
        (value(e, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }
}

/// An app, as a row of the ☮ menu.
final class AppRow: NSObject {
    let url: URL
    init(url: URL) { self.url = url }
}

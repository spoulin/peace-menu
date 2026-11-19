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
    let pid: pid_t
    let name: String
    let bundleID: String?
    let url: URL?
    let icon: NSImage?
    /// Its standard windows, newest first.
    let windows: [AXUIElement]
}

/// How much each app is used: every time an app comes to the front, its score goes up by one
/// and every score fades a little, so what's used lately counts most.
enum Usage {
    private static let key = "appUsage"

    static func scores() -> [String: Double] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
    }

    static func record(_ bundleID: String) {
        var s = scores().mapValues { $0 * 0.995 }.filter { $0.value > 0.05 }
        s[bundleID, default: 0] += 1
        UserDefaults.standard.set(s, forKey: key)
    }
}

/// An app in the Dock, kept there or running.
struct DockApp {
    let name: String
    let bundleID: String
    let url: URL
    let badge: String?
    let isRunning: Bool
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

    /// The apps in the Dock, in its order, with their badge and whether they're running.
    /// Folders, the Trash and minimized windows are left out. Any thread but the main one.
    static func dockApps() -> [DockApp] {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return [] }
        let dockElement = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(dockElement, 0.5)
        let running = Set(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.compactMap(\.bundleIdentifier))
        var found: [DockApp] = []
        for list in children(of: dockElement) where value(list, kAXRoleAttribute) as? String == kAXListRole {
            for item in children(of: list) where value(item, kAXSubroleAttribute) as? String == "AXApplicationDockItem" {
                guard let url = value(item, kAXURLAttribute) as? URL, let id = bundleID(for: url),
                      !found.contains(where: { $0.bundleID == id }) else { continue }
                let label = value(item, "AXStatusLabel") as? String
                found.append(DockApp(name: value(item, kAXTitleAttribute) as? String ?? url.deletingPathExtension().lastPathComponent,
                                     bundleID: id, url: url, badge: label?.isEmpty == false ? label : nil,
                                     isRunning: running.contains(id)))
            }
        }
        return found
    }

    /// The regular running apps, by name, with their standard windows counted (Accessibility
    /// sees those of the current Space, and minimized ones). Any thread but the main one.
    static func running() -> [RunningApp] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() }
            .map { RunningApp(pid: $0.processIdentifier, name: $0.localizedName ?? $0.bundleIdentifier ?? "?", bundleID: $0.bundleIdentifier,
                              url: $0.bundleURL, icon: $0.icon, windows: standardWindows(of: $0.processIdentifier)) }
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

    private static func standardWindows(of pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        let windows = (value(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        return windows.filter { value($0, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole }
    }

    static func title(of window: AXUIElement) -> String { value(window, kAXTitleAttribute) as? String ?? "" }

    static func isMinimized(_ window: AXUIElement) -> Bool { value(window, kAXMinimizedAttribute) as? Bool ?? false }

    /// Brings the app to the front with this window on top, out of the Dock if minimized.
    static func open(_ url: URL, window: AXUIElement) {
        if isMinimized(window) { AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse) }
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        open(url)
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
    /// One of the app's windows, for a row of its window submenu.
    let window: AXUIElement?
    /// The running app, for Force Quit.
    let pid: pid_t?
    init(url: URL, window: AXUIElement? = nil, pid: pid_t? = nil) { self.url = url; self.window = window; self.pid = pid }
}

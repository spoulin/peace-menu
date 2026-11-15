import AppKit
import ApplicationServices

/// A menu bar item as it is right now. Frames are in global screen coordinates with
/// the origin at the top left of the main display (the Core Graphics convention).
struct LiveItem {
    let key: String
    let name: String
    let bundleID: String
    let pid: pid_t
    let frame: CGRect
    /// Clock and Control Center: macOS keeps them at the right end, they can't move.
    let isFixed: Bool
    /// One of PeaceMenu's own items (icon, separators).
    let isOurs: Bool

    var ref: ItemRef { ItemRef(key: key, name: name, bundleID: bundleID) }
    var icon: NSImage? { NSRunningApplication(processIdentifier: pid)?.icon }
}

/// Reads every app's menu bar items through the Accessibility API.
/// On macOS 26 the item windows all belong to Control Center, so the window list
/// can't tell whose they are; each app's "AXExtrasMenuBar" can.
enum Scanner {
    static let fixedIDs: Set<String> = ["com.apple.menuextra.clock", "com.apple.menuextra.controlcenter"]

    static let systemNames: [String: String] = [
        "battery": "Batterie", "wifi": "Wi‑Fi", "bluetooth": "Bluetooth", "focusmode": "Concentration",
        "now-playing": "À l'écoute", "sound": "Son", "display": "Écran", "airdrop": "AirDrop",
        "screenmirroring": "Recopie de l'écran", "keyboardbrightness": "Luminosité du clavier",
        "textinput": "Saisie", "timemachine": "Time Machine", "vpn": "VPN", "user": "Utilisateur",
        "accessibility": "Accessibilité", "hearing": "Audition", "stagemanager": "Stage Manager",
        "siri": "Siri", "spotlight": "Spotlight", "weather": "Météo", "voicecontrol": "Contrôle vocal",
    ]

    /// All items of the other apps (PeaceMenu's own are added by the caller: asking our own
    /// process through Accessibility would need the main thread). Sorted from left to right.
    static func scan() -> [LiveItem] {
        var out: [LiveItem] = []
        let me = getpid()
        for app in NSWorkspace.shared.runningApplications where app.processIdentifier != me {
            let ax = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(ax, 0.25)
            guard let bar = element(ax, "AXExtrasMenuBar"), let kids = children(bar) else { continue }
            let bundle = app.bundleIdentifier ?? app.localizedName ?? "pid\(app.processIdentifier)"
            let appName = app.localizedName ?? bundle
            var found: [(String, String, CGRect, Bool)] = []
            var n = 0
            for k in kids {
                guard let f = frame(k), f.width > 0, f.height > 0 else { continue }
                let ident = string(k, kAXIdentifierAttribute) ?? ""
                let key = ident.isEmpty ? "\(bundle)#\(n)" : ident
                var name = appName
                if ident.hasPrefix("com.apple.menuextra.") {
                    let short = String(ident.dropFirst("com.apple.menuextra.".count))
                    name = systemNames[short] ?? short.capitalized
                }
                found.append((key, name, f, fixedIDs.contains(ident)))
                n += 1
            }
            let generic = found.filter { !$0.0.hasPrefix("com.apple.menuextra.") }.count
            var i = 0
            for (key, name, f, fixed) in found {
                var label = name
                if generic > 1 && !key.hasPrefix("com.apple.menuextra.") { i += 1; label = "\(name) \(i)" }
                out.append(LiveItem(key: key, name: label, bundleID: bundle, pid: app.processIdentifier,
                                    frame: f, isFixed: fixed, isOurs: false))
            }
        }
        return out.sorted { $0.frame.minX < $1.frame.minX }
    }

    // MARK: Accessibility helpers

    static func value(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success ? v : nil
    }

    static func element(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
        guard let v = value(el, attr), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func children(_ el: AXUIElement) -> [AXUIElement]? {
        value(el, kAXChildrenAttribute) as? [AXUIElement]
    }

    static func string(_ el: AXUIElement, _ attr: String) -> String? {
        value(el, attr) as? String
    }

    static func frame(_ el: AXUIElement) -> CGRect? {
        guard let p = value(el, kAXPositionAttribute), let s = value(el, kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var pt = CGPoint.zero, sz = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &pt)
        AXValueGetValue(s as! AXValue, .cgSize, &sz)
        return CGRect(origin: pt, size: sz)
    }

    /// Right edge of the frontmost app's menus (File, Edit…), which cover items behind them.
    static func appMenusEnd() -> CGFloat {
        guard let app = NSWorkspace.shared.menuBarOwningApplication, app.processIdentifier != getpid() else { return 300 }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 0.25)
        guard let bar = element(ax, kAXMenuBarAttribute), let kids = children(bar) else { return 300 }
        return kids.compactMap { frame($0)?.maxX }.max() ?? 300
    }
}

import AppKit
import SwiftUI
import ServiceManagement

/// Owns PeaceMenu's items in the menu bar. From right to left:
///
///     [hidden …] ‹ [ungrouped] [group 2 items] │G2 [group 1 items] │G1 ☮ [always visible] clock
///
/// ☮ shows or hides everything left of ‹ by stretching ‹ to 10 000 points, which pushes
/// those items off the screen. A profile says which groups sit between ☮ and ‹; applying
/// it Command-drags the items into place.
final class Controller: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static let mainKey = "peacemenu.main"
    static let hiddenKey = "peacemenu.hidden"
    static func sepKey(_ id: UUID) -> String { "peacemenu.sep.\(id.uuidString)" }

    let store = Store.shared
    let live = LiveItemsModel()

    private var mainItem: NSStatusItem!
    private var hiddenItem: NSStatusItem!
    private var separators: [UUID: NSStatusItem] = [:]

    private(set) var isHidden = false
    private var autoHideTimer: Timer?
    private var settingsWindow: NSWindow?

    /// What the bar shows now: the active profile, plus any group toggled from the menu.
    private(set) var visibleGroups: Set<UUID> = []
    private(set) var showUngrouped = false

    private let layoutQueue = DispatchQueue(label: "peacemenu.layout")
    private var layoutRunning = false
    private var layoutPending = false

    // MARK: Launch

    func applicationDidFinishLaunching(_ note: Notification) {
        // First launch: put ☮ and ‹ at the right end, next to Control Center, so every
        // other item starts out on the hidden side (like Ice).
        let d = UserDefaults.standard
        for (name, pos) in [("PeaceMain", 0), ("PeaceHidden", 1)] where d.object(forKey: "NSStatusItem Preferred Position \(name)") == nil {
            d.set(pos, forKey: "NSStatusItem Preferred Position \(name)")
        }

        enqueueCreation(key: Self.mainKey) { [unowned self] in
            mainItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            mainItem.autosaveName = "PeaceMain"
            mainItem.behavior = []
            if let b = mainItem.button {
                b.image = symbol("peacesign")
                b.target = self
                b.action = #selector(mainClicked(_:))
                b.sendAction(on: [.leftMouseUp, .rightMouseUp])
                b.toolTip = "PeaceMenu — clic : afficher/masquer, clic droit : menu"
            }
        }
        enqueueCreation(key: Self.hiddenKey) { [unowned self] in
            hiddenItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            hiddenItem.autosaveName = "PeaceHidden"
            hiddenItem.behavior = []
            if let b = hiddenItem.button {
                b.target = self
                b.action = #selector(hiddenClicked(_:))
            }
        }
        whenItemsReady { [unowned self] in
            loadActiveProfile()
            syncSeparators()
            store.onChange = { [weak self] in self?.syncSeparators() }
            whenItemsReady { [unowned self] in finishLaunching() }
        }
    }

    private func finishLaunching() {
        setHidden(false, autoHide: false)

        let trusted = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        log("launch, accessibility \(trusted)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            if trusted { self.applyLayout(thenHide: self.store.config.hideOnLaunch) }
            else if self.store.config.hideOnLaunch { self.setHidden(true) }
        }
    }

    // MARK: Creating our items

    /// Windows of PeaceMenu's own items, noted as each one is created. Every item window now
    /// belongs to Control Center, so this is the only sure way to know which ones are ours.
    private var ownWindows: [String: [CGWindowID]] = [:]
    private var pendingCreations: [(String, () -> Void)] = []
    private var creating = false
    private var afterCreations: [() -> Void] = []

    /// Creates status items one at a time and notes the windows each one adds.
    private func enqueueCreation(key: String, _ make: @escaping () -> Void) {
        pendingCreations.append((key, make))
        runCreations()
    }

    private func whenItemsReady(_ f: @escaping () -> Void) {
        afterCreations.append(f)
        runCreations()
    }

    private func runCreations() {
        guard !creating else { return }
        guard !pendingCreations.isEmpty else {
            let waiting = afterCreations
            afterCreations = []
            waiting.forEach { $0() }
            return
        }
        creating = true
        let (key, make) = pendingCreations.removeFirst()
        let before = Set(Mover.menuBarWindows())
        make()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            ownWindows[key] = Mover.menuBarWindows().filter { !before.contains($0) }
            log("windows for \(key): \(ownWindows[key] ?? [])")
            creating = false
            runCreations()
        }
    }

    private func symbol(_ name: String, size: CGFloat = 15) -> NSImage? {
        let img = NSImage(systemSymbolName: name, accessibilityDescription: name)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .regular))
        img?.isTemplate = true
        return img
    }

    // MARK: Showing and hiding

    func setHidden(_ hidden: Bool, autoHide: Bool = true) {
        log("setHidden \(hidden) autoHide \(autoHide)")
        isHidden = hidden
        autoHideTimer?.invalidate()
        if hidden {
            hiddenItem.button?.image = nil
            hiddenItem.length = 10_000
        } else {
            hiddenItem.length = NSStatusItem.variableLength
            hiddenItem.button?.image = symbol("chevron.compact.left", size: 13)
            let delay = store.config.autoHideDelay
            if autoHide && delay > 0 {
                autoHideTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                    guard let self, !self.layoutRunning else { return }
                    self.setHidden(true)
                }
            }
        }
    }

    @objc private func mainClicked(_ sender: NSStatusBarButton) {
        let e = NSApp.currentEvent
        log("mainClicked type \(String(describing: e?.type.rawValue)) flags \(String(describing: e?.modifierFlags.rawValue)) hidden \(isHidden)")
        if e?.type == .rightMouseUp || e?.modifierFlags.contains(.control) == true || e?.modifierFlags.contains(.option) == true {
            showMenu(buildMainMenu(), on: mainItem)
        } else {
            setHidden(!isHidden)
        }
    }

    @objc private func hiddenClicked(_ sender: NSStatusBarButton) {
        setHidden(true)
    }

    private func showMenu(_ menu: NSMenu, on item: NSStatusItem) {
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    // MARK: Profiles and groups

    private func loadActiveProfile() {
        let p = store.activeProfile
        visibleGroups = Set(p?.visibleGroups ?? store.config.groups.map(\.id))
        showUngrouped = p?.showUngrouped ?? false
    }

    func activateProfile(_ id: UUID) {
        store.config.activeProfile = id
        loadActiveProfile()
        syncSeparators()
        applyLayout(thenHide: isHidden)
    }

    func toggleGroup(_ id: UUID) {
        if visibleGroups.contains(id) { visibleGroups.remove(id) } else { visibleGroups.insert(id) }
        syncSeparators()
        applyLayout(thenHide: isHidden)
    }

    /// One status item per group, shown only while the group is visible.
    func syncSeparators() {
        let groups = store.config.groups
        for (id, item) in separators where !groups.contains(where: { $0.id == id }) {
            NSStatusBar.system.removeStatusItem(item)
            separators[id] = nil
            ownWindows[Self.sepKey(id)] = nil
        }
        // A hidden group's separator stays in the bar, behind ‹ with its icons: removing and
        // re-adding it would give it new windows.
        for g in groups {
            if let item = separators[g.id] {
                style(item, for: g)
            } else if !pendingCreations.contains(where: { $0.0 == Self.sepKey(g.id) }) {
                enqueueCreation(key: Self.sepKey(g.id)) { [unowned self] in
                    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                    item.autosaveName = "PeaceSep-\(g.id.uuidString)"
                    item.behavior = []
                    item.button?.target = self
                    item.button?.action = #selector(separatorClicked(_:))
                    item.button?.identifier = NSUserInterfaceItemIdentifier(g.id.uuidString)
                    separators[g.id] = item
                    if let current = store.config.groups.first(where: { $0.id == g.id }) { style(item, for: current) }
                }
            }
        }
    }

    private func style(_ item: NSStatusItem, for g: MenuGroup) {
        guard let b = item.button else { return }
        b.title = ""
        b.attributedTitle = NSAttributedString(string: "")
        b.image = nil
        b.toolTip = g.name
        switch g.style {
        case .line:
            item.length = 9
            b.image = NSImage(size: NSSize(width: 9, height: 16), flipped: false) { r in
                NSColor.black.setFill()
                NSBezierPath(roundedRect: NSRect(x: 4, y: 1, width: 1, height: 14), xRadius: 0.5, yRadius: 0.5).fill()
                return true
            }
            b.image?.isTemplate = true
        case .dot:
            item.length = 12
            b.image = symbol("circle.fill", size: 5)
        case .label:
            item.length = NSStatusItem.variableLength
            b.attributedTitle = NSAttributedString(string: g.name, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
        case .symbol:
            item.length = NSStatusItem.variableLength
            b.image = symbol(g.symbol, size: 12)
        case .space:
            item.length = 10
        }
    }

    @objc private func separatorClicked(_ sender: NSStatusBarButton) {
        guard let raw = sender.identifier?.rawValue, let id = UUID(uuidString: raw),
              let g = store.config.groups.first(where: { $0.id == id }), let item = separators[id] else { return }
        let menu = NSMenu()
        let title = NSMenuItem(title: g.name, action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        let hide = NSMenuItem(title: "Masquer ce groupe", action: #selector(toggleGroupFromMenu(_:)), keyEquivalent: "")
        hide.representedObject = id
        hide.target = self
        menu.addItem(hide)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Réglages…", action: #selector(openSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        showMenu(menu, on: item)
    }

    // MARK: Menu

    private func buildMainMenu() -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector?, _ obj: Any? = nil, key: String = "", on: Bool = false, enabled: Bool = true) {
            let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
            it.target = self
            it.representedObject = obj
            it.state = on ? .on : .off
            it.isEnabled = enabled
            menu.addItem(it)
        }

        if !AXIsProcessTrusted() {
            add("⚠︎ Autoriser l'Accessibilité…", #selector(openAccessibility))
            menu.addItem(.separator())
        }

        menu.addItem(.sectionHeader(title: "Profils"))
        for p in store.config.profiles {
            add(p.name, #selector(profileFromMenu(_:)), p.id, on: p.id == store.activeProfile?.id)
        }
        if !store.config.groups.isEmpty {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: "Groupes affichés"))
            for g in store.config.groups {
                add(g.name, #selector(toggleGroupFromMenu(_:)), g.id, on: visibleGroups.contains(g.id))
            }
        }
        add("Icônes sans groupe", #selector(toggleUngrouped), on: showUngrouped)

        menu.addItem(.separator())
        add(isHidden ? "Afficher les icônes cachées" : "Masquer les icônes", #selector(toggleHidden))
        add(layoutRunning ? "Rangement en cours…" : "Ranger la barre maintenant", #selector(relayout), enabled: !layoutRunning)
        add("Réglages…", #selector(openSettings), key: ",")
        menu.addItem(.separator())
        add("Quitter PeaceMenu", #selector(quit), key: "q")
        return menu
    }

    @objc private func profileFromMenu(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? UUID { activateProfile(id) }
    }
    @objc private func toggleGroupFromMenu(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? UUID { toggleGroup(id) }
    }
    @objc private func toggleUngrouped() {
        showUngrouped.toggle()
        applyLayout(thenHide: isHidden)
    }
    @objc private func toggleHidden() { setHidden(!isHidden) }
    @objc private func relayout() { applyLayout(thenHide: isHidden) }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let view = SettingsView(store: store, live: live, controller: self)
            let w = NSWindow(contentViewController: NSHostingController(rootView: view))
            w.title = "PeaceMenu"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.setContentSize(NSSize(width: 760, height: 520))
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        live.refresh(controller: self)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: Layout

    /// PeaceMenu's own items with their frames. Main thread only.
    func ownItems() -> [LiveItem] {
        guard let mainH = NSScreen.screens.first?.frame.height else { return [] }
        var list: [(String, String, NSStatusItem)] = [(Self.mainKey, "PeaceMenu", mainItem), (Self.hiddenKey, "Séparateur caché", hiddenItem)]
        for g in store.config.groups { if let s = separators[g.id] { list.append((Self.sepKey(g.id), "│ \(g.name)", s)) } }
        return list.compactMap { key, name, item in
            guard item.isVisible, let w = item.button?.window else { return nil }
            let f = w.frame
            return LiveItem(key: key, name: name, bundleID: Bundle.main.bundleIdentifier ?? "peacemenu", pid: getpid(),
                            frame: CGRect(x: f.minX, y: mainH - f.maxY, width: f.width, height: f.height),
                            isFixed: false, isOurs: true)
        }
    }

    /// Every item, ours included, from any thread but the main one.
    private func snapshot() -> [LiveItem] {
        let ours = DispatchQueue.main.sync { ownItems() }
        return (Scanner.scan() + ours).sorted { $0.frame.minX < $1.frame.minX }
    }

    /// Rearranges the bar for the visible groups. Runs in the background; a request made
    /// while one is running runs once it's done.
    func applyLayout(thenHide: Bool) {
        guard AXIsProcessTrusted() else { openAccessibility(); return }
        if creating || !pendingCreations.isEmpty {
            whenItemsReady { [weak self] in self?.applyLayout(thenHide: thenHide) }
            return
        }
        if layoutRunning { layoutPending = true; return }
        layoutRunning = true
        setHidden(false, autoHide: false)
        mainItem.button?.image = symbol("hourglass")

        let groups = store.config.groups
        let visible = visibleGroups, ungrouped = showUngrouped
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            self.layoutQueue.async {
                let failed = self.runLayout(groups: groups, visible: visible, showUngrouped: ungrouped)
                DispatchQueue.main.async {
                    self.layoutRunning = false
                    self.mainItem.button?.image = self.symbol("peacesign")
                    if !failed.isEmpty { self.mainItem.button?.toolTip = "PeaceMenu — pas pu déplacer : \(failed.joined(separator: ", "))" }
                    self.live.refresh(controller: self)
                    if self.layoutPending {
                        self.layoutPending = false
                        self.applyLayout(thenHide: thenHide)
                    } else {
                        self.setHidden(thenHide)
                    }
                }
            }
        }
    }

    /// Returns the names of items it couldn't move.
    private func runLayout(groups: [MenuGroup], visible: Set<UUID>, showUngrouped: Bool) -> [String] {
        // Accessibility says whose item is whose; after that, positions come from the window
        // server, which is exact and immediate.
        Thread.sleep(forTimeInterval: 0.3)
        let items = snapshot()
        let known = DispatchQueue.main.sync { ownWindows }
        let windows = Mover.attachWindows(to: items, known: known)
        func frame(_ key: String) -> CGRect? { windows[key].flatMap(Mover.frame(of:)) }
        let names = Dictionary(items.map { ($0.key, $0.name) }, uniquingKeysWith: { a, _ in a })

        guard let mainFrame = frame(Self.mainKey), windows[Self.hiddenKey] != nil else {
            log("layout: PeaceMenu's own items not found")
            return []
        }
        let assigned = Set(groups.flatMap { $0.items.map(\.key) })

        // Right to left, starting just left of ☮.
        var desired: [String] = []
        for g in groups where visible.contains(g.id) {
            desired.append(Self.sepKey(g.id))
            desired += g.items.map(\.key)
        }
        if showUngrouped {
            desired += items.filter { !$0.isOurs && !$0.isFixed && !assigned.contains($0.key) }
                .compactMap { it in frame(it.key).map { (it.key, $0) } }
                .filter { $0.1.maxX <= mainFrame.minX + 1 }
                .sorted { $0.1.minX > $1.1.minX }.map(\.0)
        }
        desired.append(Self.hiddenKey)

        var failed: [String] = []
        log("layout start: \(windows.count) of \(items.count) items matched, desired: \(desired)")
        defer { log("layout done, failed: \(failed)") }

        /// The known item drawn just left of `key`.
        func leftNeighbour(of key: String) -> String? {
            guard let f = frame(key) else { return nil }
            return windows.keys.filter { $0 != key }
                .compactMap { k in frame(k).map { (k, $0) } }
                .filter { $0.1.maxX <= f.minX + 2 }
                .max { $0.1.maxX < $1.1.maxX }?.0
        }

        func place(_ key: String, leftOf anchorKey: String) -> Bool {
            guard let w = windows[key], let a = windows[anchorKey] else { return false }
            for _ in 0..<3 {
                if leftNeighbour(of: anchorKey) == key { return true }
                Mover.move(w, leftOf: a)
            }
            if leftNeighbour(of: anchorKey) == key { return true }
            failed.append(names[key] ?? key)
            return false
        }

        var anchor = Self.mainKey
        for key in desired where windows[key] != nil {
            if place(key, leftOf: anchor) { anchor = key }
        }

        // Items of hidden groups that sit right of ‹ (for example next to the clock) go behind it.
        let hiddenKeys = groups.filter { !visible.contains($0.id) }.flatMap { $0.items.map(\.key) }
        for key in hiddenKeys {
            guard let sep = frame(Self.hiddenKey), let f = frame(key), f.minX > sep.minX else { continue }
            _ = place(key, leftOf: Self.hiddenKey)
        }
        return failed
    }
}

/// Appends to ~/Library/Logs/PeaceMenu.log.
func log(_ s: String) {
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/PeaceMenu.log")
    let line = "\(Date().formatted(date: .omitted, time: .standard)) \(s)\n"
    if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
    else { try? line.write(to: url, atomically: true, encoding: .utf8) }
}

/// The items the settings window lists. Refreshed in the background.
final class LiveItemsModel: ObservableObject {
    @Published var items: [LiveItem] = []

    func refresh(controller: Controller) {
        DispatchQueue.global(qos: .userInitiated).async {
            let found = Scanner.scan().filter { !$0.isFixed }.sorted { $0.frame.minX > $1.frame.minX }
            DispatchQueue.main.async { self.items = found }
        }
    }
}

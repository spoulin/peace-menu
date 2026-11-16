import AppKit
import SwiftUI
import ServiceManagement

/// Owns PeaceMenu's items in the menu bar. From right to left:
///
///     [hidden …] ‹ [unhideable] [ungrouped] G2│ [group 2 items] G1│ [group 1 items] ☮ ┆ [always visible] clock
///
/// "Unhideable" items are the ones macOS never lets an app hide, such as the purple
/// screen-recording indicator. They come and go; PeaceMenu keeps them at the left end.
/// ┆ ends PeaceMenu's part of the bar, before the items that are always visible.
///
/// ☮ shows or hides everything left of ‹ by stretching ‹ to 10 000 points, which pushes
/// those items off the screen. A profile says which groups sit between ☮ and ‹; applying
/// it Command-drags the items into place.
final class Controller: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static let mainKey = "peacemenu.main"
    static let hiddenKey = "peacemenu.hidden"
    static let systemKey = "peacemenu.system"
    static func sepKey(_ id: UUID) -> String { "peacemenu.sep.\(id.uuidString)" }

    let store = Store.shared
    let live = LiveItemsModel()

    private var mainItem: NSStatusItem!
    private var hiddenItem: NSStatusItem!
    private var systemItem: NSStatusItem!
    /// Unhideable items present the last time the watcher looked.
    private var unhideable: Set<String> = []
    private var watchTimer: Timer?
    private var separators: [UUID: NSStatusItem] = [:]

    private(set) var isHidden = false
    private var autoHideTimer: Timer?
    private var settingsWindow: NSWindow?

    /// What the bar shows now: the active profile, plus any group toggled from the menu.
    private(set) var visibleGroups: Set<UUID> = []
    private(set) var showUngrouped = false

    /// The last state seen for each icon of a folded group, and the groups with an icon
    /// that changed since they were folded.
    private var baseline: [String: String] = [:]
    private(set) var changedGroups: Set<UUID> = []
    private var stateTimer: Timer?
    private var checkingStates = false
    private var peekTimers: [String: Timer] = [:]

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
        enqueueCreation(key: Self.systemKey) { [unowned self] in
            systemItem = NSStatusBar.system.statusItem(withLength: 9)
            systemItem.autosaveName = "PeaceSystem"
            systemItem.behavior = []
            systemItem.button?.toolTip = "À droite : icônes toujours affichées"
            styleSystemSeparator()
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
            self.watchTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.watchUnhideable() }
            self.stateTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.checkStates() }
        }
    }

    // MARK: Unhideable items

    /// Notices unhideable items appearing or leaving. When one appears, moves it to the left
    /// end without revealing the hidden icons.
    private func watchUnhideable() {
        guard AXIsProcessTrusted(), !layoutRunning else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let present = Scanner.unhideablePresent()
            DispatchQueue.main.async {
                guard let self, !self.layoutRunning, present != self.unhideable else { return }
                log("unhideable items now: \(present.sorted())")
                let appeared = !present.subtracting(self.unhideable).isEmpty
                self.unhideable = present
                guard appeared else { return }
                self.layoutRunning = true
                self.layoutQueue.async {
                    Thread.sleep(forTimeInterval: 0.3) // let ┆ take its width
                    let failed = self.placeUnhideable()
                    DispatchQueue.main.async {
                        self.layoutRunning = false
                        if !failed.isEmpty { log("unhideable not moved: \(failed)") }
                        if self.layoutPending { self.layoutPending = false; self.applyLayout(thenHide: self.isHidden) }
                    }
                }
            }
        }
    }

    /// ┆ is a dotted line.
    private func styleSystemSeparator() {
        guard let b = systemItem?.button else { return }
        b.image = NSImage(size: NSSize(width: 9, height: 16), flipped: false) { _ in
            NSColor.black.setFill()
            for y in stride(from: 1.0, to: 15.0, by: 3.0) { NSBezierPath(rect: NSRect(x: 4, y: y, width: 1, height: 1.5)).fill() }
            return true
        }
        b.image?.isTemplate = true
    }

    /// Puts the unhideable items just left of the first item right of ‹. Nothing hidden is
    /// revealed: everything involved sits right of ‹, so it's drawn.
    private func placeUnhideable() -> [String] {
        let present = DispatchQueue.main.sync { unhideable }
        guard !present.isEmpty else { return [] }
        let p = Placer(items: snapshot(quick: true), known: DispatchQueue.main.sync { ownWindows })
        guard let sep = p.frame(Self.hiddenKey) else { return [] }
        let skip = present.union([Self.hiddenKey])
        guard let first = p.windows.keys.filter({ !skip.contains($0) })
            .compactMap({ k in p.frame(k).map { (k, $0) } })
            .filter({ $0.1.minX >= sep.maxX - 1 })
            .min(by: { $0.1.minX < $1.1.minX })?.0 else { return [] }
        var anchor = first
        for key in present.sorted() where p.windows[key] != nil {
            if p.place(key, leftOf: anchor) { anchor = key }
        }
        return p.failed
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
                    item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
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
        b.toolTip = "\(g.name) — clic : \(g.collapsed ? "afficher" : "replier") les icônes, clic droit : menu"
        b.imagePosition = .imageLeading
        // A name or a symbol gets an arrow that says whether the icons are shown. A line, a dot
        // or a space becomes ▸ while the icons are folded, so something says they're there.
        // An orange dot before the arrow says an icon of the folded group changed.
        let arrow = g.collapsed ? "▸" : "▾"
        let changed = g.collapsed && changedGroups.contains(g.id)
        if changed { b.toolTip = "\(g.name) — une icône a changé. Clic : afficher les icônes" }
        func arrowTitle(_ text: String) {
            item.length = NSStatusItem.variableLength
            let font = NSFont.systemFont(ofSize: 11, weight: .medium)
            let title = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
            if changed, let r = text.range(of: arrow, options: .backwards) {
                title.insert(NSAttributedString(string: "●", attributes: [.font: NSFont.systemFont(ofSize: 8), .foregroundColor: NSColor.systemOrange, .baselineOffset: 1]),
                             at: NSRange(r, in: text).location)
            }
            b.attributedTitle = title
        }
        if g.collapsed && [.line, .dot, .space].contains(g.style) { arrowTitle(arrow); return }
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
            arrowTitle("\(g.name) \(arrow)")
        case .symbol:
            arrowTitle(" \(arrow)")
            b.image = symbol(g.symbol, size: 12)
        case .space:
            item.length = 10
        }
    }

    @objc private func separatorClicked(_ sender: NSStatusBarButton) {
        guard let raw = sender.identifier?.rawValue, let id = UUID(uuidString: raw),
              let g = store.config.groups.first(where: { $0.id == id }), let item = separators[id] else { return }
        let e = NSApp.currentEvent
        // A left click, or a press through Accessibility (no mouse event).
        let plain = e?.type != .rightMouseUp && e?.modifierFlags.intersection([.control, .option]).isEmpty != false
        if plain { setCollapsed(id, !g.collapsed); return }
        let menu = NSMenu()
        let title = NSMenuItem(title: g.name, action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        let fold = NSMenuItem(title: g.collapsed ? "Afficher les icônes" : "Replier les icônes", action: #selector(toggleCollapsedFromMenu(_:)), keyEquivalent: "")
        fold.representedObject = id
        fold.target = self
        menu.addItem(fold)
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

    // MARK: Folding groups

    @objc private func toggleCollapsedFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let g = store.config.groups.first(where: { $0.id == id }) else { return }
        setCollapsed(id, !g.collapsed)
    }

    /// Shows or folds a group's icons: moves them next to its separator, or back behind ‹.
    /// The choice is saved. The rest of the bar stays as it is; nothing hidden is revealed.
    func setCollapsed(_ id: UUID, _ collapsed: Bool) {
        guard let i = store.config.groups.firstIndex(where: { $0.id == id }),
              store.config.groups[i].collapsed != collapsed else { return }
        // Seen or folded again: what the icons show now is the new normal.
        changedGroups.remove(id)
        for ref in store.config.groups[i].items {
            baseline[ref.key] = nil
            peekTimers.removeValue(forKey: ref.key)?.invalidate()
        }
        store.config.groups[i].collapsed = collapsed // restyles the separator
        let g = store.config.groups[i]
        guard AXIsProcessTrusted(), visibleGroups.contains(id) else { return }
        moveFolded(g)
    }

    private func moveFolded(_ g: MenuGroup) {
        if layoutRunning || creating {
            // Moves only once the running one is done, and only if the choice still holds.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, let now = self.store.config.groups.first(where: { $0.id == g.id }), now.collapsed == g.collapsed else { return }
                self.moveFolded(now)
            }
            return
        }
        layoutRunning = true
        let id = g.id, folding = g.collapsed
        let keys = g.items.map(\.key).filter { !Scanner.isUnhideable($0) }
        layoutQueue.async {
            Thread.sleep(forTimeInterval: 0.15) // let the arrow's new width settle
            let p = Placer(items: self.snapshot(quick: true), known: DispatchQueue.main.sync { self.ownWindows })
            if folding {
                for key in keys where p.windows[key] != nil { p.hide(key, behind: Self.hiddenKey) }
            } else {
                p.show(keys, rightOf: Self.sepKey(id))
            }
            log("group \(g.name) \(folding ? "folded" : "shown"), failed: \(p.failed)")
            DispatchQueue.main.async {
                self.layoutRunning = false
                if self.layoutPending { self.layoutPending = false; self.applyLayout(thenHide: self.isHidden) }
            }
        }
    }

    // MARK: Watching folded icons

    /// Every few seconds, reads the state of the icons in folded groups. A change puts a dot on
    /// the group's title and, if asked, brings the icon into the bar for a moment.
    private func checkStates() {
        let mode = store.config.changeSignal
        let folded = store.config.groups.filter { $0.collapsed && visibleGroups.contains($0.id) }
        guard mode != .off, !folded.isEmpty, AXIsProcessTrusted(), !checkingStates, !layoutRunning else { return }
        checkingStates = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let states = Dictionary(Scanner.scan(quick: true).map { ($0.key, $0.state) }, uniquingKeysWith: { a, _ in a })
            DispatchQueue.main.async {
                guard let self else { return }
                self.checkingStates = false
                for g in folded {
                    // The group may have been opened while the scan ran.
                    guard self.store.config.groups.first(where: { $0.id == g.id })?.collapsed == true else { continue }
                    for ref in g.items where !Scanner.isUnhideable(ref.key) {
                        guard let now = states[ref.key] else { continue }
                        defer { self.baseline[ref.key] = now }
                        guard let before = self.baseline[ref.key], before != now else { continue }
                        log("changed in \(g.name): \(ref.name) [\(before)] → [\(now)]")
                        self.changedGroups.insert(g.id)
                        if let item = self.separators[g.id] { self.style(item, for: g) }
                        if self.store.config.changeSignal == .peek { self.peek(ref.key, in: g.id) }
                    }
                }
            }
        }
    }

    /// Brings one icon of a folded group next to its title, then puts it back behind ‹.
    private func peek(_ key: String, in groupID: UUID) {
        guard peekTimers[key] == nil else { return } // already showing
        guard !layoutRunning, !creating else { return } // the dot stays; no need to insist
        layoutRunning = true
        layoutQueue.async {
            let p = Placer(items: self.snapshot(quick: true), known: DispatchQueue.main.sync { self.ownWindows })
            p.show([key], rightOf: Self.sepKey(groupID))
            log("peek \(p.names[key] ?? key), failed: \(p.failed)")
            DispatchQueue.main.async {
                self.layoutRunning = false
                if self.layoutPending { self.layoutPending = false; self.applyLayout(thenHide: self.isHidden) }
                let delay = self.store.config.autoHideDelay > 0 ? self.store.config.autoHideDelay : 10
                self.peekTimers[key] = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                    self?.endPeek(key, in: groupID)
                }
            }
        }
    }

    private func endPeek(_ key: String, in groupID: UUID) {
        guard peekTimers[key] != nil else { return } // the group was opened or folded since
        // Opened since: the icon stays where it is.
        guard store.config.groups.first(where: { $0.id == groupID })?.collapsed == true else { peekTimers[key] = nil; return }
        if layoutRunning || creating {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.endPeek(key, in: groupID) }
            return
        }
        peekTimers[key] = nil
        layoutRunning = true
        layoutQueue.async {
            let p = Placer(items: self.snapshot(quick: true), known: DispatchQueue.main.sync { self.ownWindows })
            if p.windows[key] != nil { p.hide(key, behind: Self.hiddenKey) }
            DispatchQueue.main.async {
                self.layoutRunning = false
                if self.layoutPending { self.layoutPending = false; self.applyLayout(thenHide: self.isHidden) }
            }
        }
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
        if let systemItem { list.append((Self.systemKey, "┆ Fin de PeaceMenu", systemItem)) }
        for g in store.config.groups { if let s = separators[g.id] { list.append((Self.sepKey(g.id), "│ \(g.name)", s)) } }
        return list.compactMap { key, name, item in
            guard item.isVisible, let w = item.button?.window else { return nil }
            let f = w.frame
            return LiveItem(key: key, name: name, bundleID: Bundle.main.bundleIdentifier ?? "peacemenu", pid: getpid(),
                            frame: CGRect(x: f.minX, y: mainH - f.maxY, width: f.width, height: f.height),
                            isFixed: false, isOurs: true)
        }
    }

    /// Every item, ours included, from any thread but the main one. `quick`: see Scanner.scan.
    private func snapshot(quick: Bool = false) -> [LiveItem] {
        let ours = DispatchQueue.main.sync { ownItems() }
        return (Scanner.scan(quick: quick) + ours).sorted { $0.frame.minX < $1.frame.minX }
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
        let visible = visibleGroups, ungrouped = showUngrouped, present = unhideable
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            self.layoutQueue.async {
                let failed = self.runLayout(groups: groups, visible: visible, showUngrouped: ungrouped, unhideable: present)
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
    private func runLayout(groups: [MenuGroup], visible: Set<UUID>, showUngrouped: Bool, unhideable: Set<String>) -> [String] {
        // Accessibility says whose item is whose; after that, positions come from the window
        // server, which is exact and immediate.
        Thread.sleep(forTimeInterval: 0.3)
        let items = snapshot()
        let p = Placer(items: items, known: DispatchQueue.main.sync { ownWindows })

        guard let mainFrame = p.frame(Self.mainKey), p.windows[Self.hiddenKey] != nil else {
            log("layout: PeaceMenu's own items not found")
            return []
        }
        let assigned = Set(groups.flatMap { $0.items.map(\.key) })

        // Right to left, starting just left of ☮.
        var desired: [String] = []
        let closed = Set(groups.filter(\.collapsed).map(\.id))
        for g in groups where visible.contains(g.id) {
            // Built right to left, so the separator comes last: it ends up left of its icons,
            // where a group's name reads like a title. A folded group keeps only its separator.
            if !closed.contains(g.id) { desired += g.items.map(\.key).filter { !Scanner.isUnhideable($0) } }
            desired.append(Self.sepKey(g.id))
        }
        if showUngrouped {
            desired += items.filter { !$0.isOurs && !$0.isFixed && !assigned.contains($0.key) && !Scanner.isUnhideable($0.key) }
                .compactMap { it in p.frame(it.key).map { (it.key, $0) } }
                .filter { $0.1.maxX <= mainFrame.minX + 1 }
                .sorted { $0.1.minX > $1.1.minX }.map(\.0)
        }
        desired += unhideable.sorted()
        desired.append(Self.hiddenKey)

        log("layout start: \(p.windows.count) of \(items.count) items matched, desired: \(desired)")
        defer { log("layout done, failed: \(p.failed)") }

        var anchor = Self.mainKey
        for key in desired where p.windows[key] != nil {
            if p.place(key, leftOf: anchor) { anchor = key }
        }

        // ┆ just right of ☮: left of whatever item comes after ☮ (Control Center at the least).
        if let next = p.rightNeighbour(of: Self.mainKey), next != Self.systemKey {
            _ = p.place(Self.systemKey, leftOf: next)
        }

        // Items of hidden groups that sit right of ‹ (for example next to the clock) go behind it.
        let hiddenKeys = groups.filter { !visible.contains($0.id) || closed.contains($0.id) }.flatMap { $0.items.map(\.key) }.filter { !Scanner.isUnhideable($0) }
        for key in hiddenKeys {
            guard let sep = p.frame(Self.hiddenKey), let f = p.frame(key), f.minX > sep.minX else { continue }
            p.hide(key, behind: Self.hiddenKey) // anywhere left of ‹ will do
        }
        return p.failed
    }
}

/// Moves items next to each other, checking each move against the window server.
final class Placer {
    let windows: [String: CGWindowID]
    let names: [String: String]
    private(set) var failed: [String] = []

    init(items: [LiveItem], known: [String: [CGWindowID]]) {
        windows = Mover.attachWindows(to: items, known: known)
        names = Dictionary(items.map { ($0.key, $0.name) }, uniquingKeysWith: { a, _ in a })
    }

    func frame(_ key: String) -> CGRect? { windows[key].flatMap(Mover.frame(of:)) }

    /// The known item drawn just left of `key`.
    func leftNeighbour(of key: String) -> String? {
        guard let f = frame(key) else { return nil }
        return windows.keys.filter { $0 != key }
            .compactMap { k in frame(k).map { (k, $0) } }
            .filter { $0.1.maxX <= f.minX + 2 }
            .max { $0.1.maxX < $1.1.maxX }?.0
    }

    /// Moves `key` behind ‹ (anywhere left of it). When ‹ is stretched its edge isn't drawn, and
    /// a drop there sends the item to the far left: hidden all the same.
    @discardableResult
    func hide(_ key: String, behind hiddenKey: String) -> Bool {
        guard let w = windows[key], let a = windows[hiddenKey] else { return false }
        func isBehind() -> Bool {
            guard let f = frame(key), let h = frame(hiddenKey) else { return false }
            return f.maxX <= h.minX + 2
        }
        for _ in 0..<3 {
            if isBehind() { return true }
            Mover.move(w, leftOf: a)
        }
        if isBehind() { return true }
        failed.append(names[key] ?? key)
        return false
    }

    /// Puts `keys` just right of `sepKey`, in order (the first one ends up rightmost).
    func show(_ keys: [String], rightOf sepKey: String) {
        let mine = Set(keys)
        guard let sepFrame = frame(sepKey),
              var anchor = windows.keys.filter({ !mine.contains($0) && $0 != sepKey })
                .compactMap({ k in frame(k).map { (k, $0) } })
                .filter({ $0.1.minX >= sepFrame.maxX - 2 })
                .min(by: { $0.1.minX < $1.1.minX })?.0 else { return }
        for key in keys where windows[key] != nil {
            if place(key, leftOf: anchor) { anchor = key }
        }
    }

    /// The known item drawn just right of `key`.
    func rightNeighbour(of key: String) -> String? {
        guard let f = frame(key) else { return nil }
        return windows.keys.filter { $0 != key }
            .compactMap { k in frame(k).map { (k, $0) } }
            .filter { $0.1.minX >= f.maxX - 2 }
            .min { $0.1.minX < $1.1.minX }?.0
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
            let found = Scanner.scan().filter { !$0.isFixed && !Scanner.isUnhideable($0.key) }.sorted { $0.frame.minX > $1.frame.minX }
            DispatchQueue.main.async { self.items = found }
        }
    }
}

import AppKit
import SwiftUI
import ServiceManagement

/// Owns PeaceMenu's items in the menu bar. From left to right:
///
///     [Off …] ‹‹ [On demand groups] ‹ [unhideable] [Always groups] ☮ [always visible] clock
///
/// "Unhideable" items are the ones macOS never lets an app hide, such as the purple
/// screen-recording indicator. They come and go; PeaceMenu keeps them just right of ‹.
///
/// ☮ shows or hides everything left of ‹ by stretching ‹ to 10 000 points, which pushes
/// those items off the screen. A profile gives each group a mode, Always, On demand or Off,
/// which says in which zone it sits; applying it Command-drags the items into place.
final class Controller: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static let mainKey = "peacemenu.main"
    static let hiddenKey = "peacemenu.hidden"
    /// ‹‹, always stretched: what's left of it never shows, not even when ☮ reveals the
    /// hidden icons. A profile's Off groups go there.
    static let alwaysKey = "peacemenu.always"
    static func sepKey(_ id: UUID) -> String { "peacemenu.sep.\(id.uuidString)" }

    let store = Store.shared
    let live = LiveItemsModel()

    private var mainItem: NSStatusItem!
    private var hiddenItem: NSStatusItem!
    private var alwaysItem: NSStatusItem?
    /// ‹‹ has been put at the far left once; from then on it stays stretched.
    private var alwaysPlaced: Bool {
        get { UserDefaults.standard.bool(forKey: "alwaysPlaced") }
        set { UserDefaults.standard.set(newValue, forKey: "alwaysPlaced") }
    }
    /// Where folded and left-out icons go.
    private var deepKey: String { alwaysPlaced ? Self.alwaysKey : Self.hiddenKey }
    /// Unhideable items present the last time the watcher looked.
    private var unhideable: Set<String> = []
    private var watchTimer: Timer?
    private var separators: [UUID: NSStatusItem] = [:]

    private(set) var isHidden = false
    private var autoHideTimer: Timer?
    private var settingsWindow: NSWindow?

    /// What the bar shows now: the active profile, plus any group toggled from the menu.
    /// The groups shown, from left to right in the bar.
    /// The active profile's groups, left to right, each Always, On demand or Off.
    private(set) var profileGroups: [ProfileGroup] = []
    private(set) var ungroupedMode: GroupMode = .onDemand
    var visibleGroups: Set<UUID> { Set(profileGroups.filter { $0.mode != .off }.map(\.id)) }
    private func mode(of id: UUID) -> GroupMode { profileGroups.first { $0.id == id }?.mode ?? .off }
    /// The hidden icons were shown by the user (☮) or by a change: whatever changed has been seen.
    private var revealedForUser = false

    /// The last state seen for each icon of a folded group, and the groups with an icon
    /// that changed since they were folded.
    private var baseline: [String: String] = [:]
    private(set) var changedGroups: Set<UUID> = []
    private var stateTimer: Timer?
    private var newItemsTimer: Timer?
    /// The icons seen at the last layout.
    private var knownKeys: Set<String> = []
    private var checkingStates = false

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
            // A fixed width: with a variable one, ☮ was sometimes clipped on the left and right
            // after the active menu bar moved to the external display (another pixel density).
            mainItem = NSStatusBar.system.statusItem(withLength: 30)
            mainItem.autosaveName = "PeaceMain"
            mainItem.behavior = []
            if let b = mainItem.button {
                b.imageScaling = .scaleProportionallyDown // shrink rather than clip
                b.imagePosition = .imageOnly
                b.image = peaceIcon()
                b.target = self
                b.action = #selector(mainClicked(_:))
                b.sendAction(on: [.leftMouseUp, .rightMouseUp])
                b.toolTip = "PeaceMenu — click: show or hide icons, right-click: menu"
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
        enqueueCreation(key: Self.alwaysKey) { [unowned self] in
            // Small until the first layout has put it at the far left: stretched anywhere
            // else, it would push the whole bar off the screen.
            let item = NSStatusBar.system.statusItem(withLength: alwaysPlaced ? 10_000 : 4)
            item.autosaveName = "PeaceAlways"
            item.behavior = []
            item.button?.toolTip = "Left of here: icons always hidden"
            alwaysItem = item
        }
        whenItemsReady { [unowned self] in
            loadActiveProfile()
            syncSeparators()
            store.onChange = { [weak self] in
                self?.syncSeparators()
                if let self, !self.layoutRunning { self.mainItem.button?.image = self.peaceIcon() }
            }
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
            self.newItemsTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.watchNewItems() }
            // A new app usually adds its icon within a few seconds of launching.
            NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] _ in
                for delay in [2.0, 5.0, 10.0] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self?.watchNewItems() }
                }
            }
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
                    Thread.sleep(forTimeInterval: 0.3) // let the new item settle
                    let failed = Mover.exclusive { self.placeUnhideable() }
                    DispatchQueue.main.async {
                        self.layoutRunning = false
                        if !failed.isEmpty { log("unhideable not moved: \(failed)") }
                        if self.layoutPending { self.layoutPending = false; self.applyLayout(thenHide: self.isHidden) }
                    }
                }
            }
        }
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
        if hidden && revealedForUser {
            revealedForUser = false
            if !changedGroups.isEmpty {
                changedGroups.removeAll()
                syncSeparators()
                refreshPeaceIcon()
            }
        }
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
            if isHidden { revealedForUser = true }
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
        profileGroups = p?.entries(for: store.config.groups) ?? store.config.groups.map { ProfileGroup(id: $0.id, mode: .always) }
        ungroupedMode = p?.ungrouped ?? .onDemand
    }

    func activateProfile(_ id: UUID) {
        store.config.activeProfile = id
        loadActiveProfile()
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
        b.toolTip = "\(g.name) — click: menu"
        b.imagePosition = .imageTrailing
        // An orange dot after the name says an icon of this On demand group changed.
        let changed = changedGroups.contains(g.id)
        if changed { b.toolTip = "\(g.name) — an icon changed" }
        // A group color paints the name, the chevron and the line, dot or symbol.
        let tint = g.color.flatMap(NSColor.init(hex:))
        defer { if let tint, let img = b.image { b.image = img.tinted(tint) } }
        func titled(_ text: String, image: NSImage?) {
            item.length = NSStatusItem.variableLength
            let title = NSMutableAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: tint ?? NSColor.secondaryLabelColor])
            if changed {
                title.append(NSAttributedString(string: (text.isEmpty ? "" : " ") + "●", attributes: [
                    .font: NSFont.systemFont(ofSize: 8), .foregroundColor: NSColor.systemOrange, .baselineOffset: 1]))
            }
            b.attributedTitle = title
            b.image = image
        }
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
            titled(g.name, image: nil)
        case .symbol:
            titled("", image: symbol(g.symbol, size: 12))
        case .space:
            item.length = 10
        }
    }

    /// ☮ as chosen in Settings. The colored ones are drawn each time the bar draws them: bright
    /// on a dark menu bar, darker on a light one, where bright yellow and cyan would fade out.
    private func peaceIcon() -> NSImage? {
        let base = basePeaceIcon()
        // An icon that changed in an On demand group (hidden) shows as a dot on ☮.
        guard !changedGroups.isEmpty, let base else { return base }
        let img = NSImage(size: base.size, flipped: false) { r in
            if base.isTemplate {
                let dark = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                base.tinted(dark ? .white : .black).draw(in: r)
            } else {
                base.draw(in: r)
            }
            NSColor.systemOrange.setFill()
            NSBezierPath(ovalIn: NSRect(x: r.maxX - 6, y: r.maxY - 6, width: 6, height: 6)).fill()
            return true
        }
        img.isTemplate = false
        img.accessibilityDescription = "PeaceMenu — an icon changed"
        return img
    }

    private func refreshPeaceIcon() {
        if !layoutRunning { mainItem.button?.image = peaceIcon() }
    }

    private func basePeaceIcon() -> NSImage? {
        let style = store.config.menuIcon
        guard style != .classic,
              let shape = NSImage(systemSymbolName: "peacesign", accessibilityDescription: "PeaceMenu")?
                .withSymbolConfiguration(.init(pointSize: 15, weight: style == .stripes ? .semibold : .medium)) else { return symbol("peacesign") }
        let img = NSImage(size: shape.size, flipped: false) { r in
            let dark = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            shape.draw(in: r)
            ctx.setBlendMode(.sourceIn)
            if style == .stripes {
                let hues: [CGFloat] = [0.0, 0.08, 0.15, 0.33, 0.55, 0.72, 0.85]
                let step = r.width / 8
                ctx.translateBy(x: r.midX, y: r.midY)
                ctx.rotate(by: .pi / 4)
                for i in -10..<10 {
                    let hue = hues[(i + 21) % hues.count]
                    ctx.setFillColor(NSColor(hue: hue, saturation: 0.9, brightness: dark ? 1 : 0.72, alpha: 1).cgColor)
                    ctx.fill(CGRect(x: CGFloat(i) * step, y: -r.width, width: step + 0.3, height: r.width * 2))
                }
            } else {
                // A rainbow turning around the center. Blue and violet are paler on a dark bar:
                // full ones sank into the black (the bottom stem is violet).
                let c = CGPoint(x: r.midX, y: r.midY), n = 72
                for i in 0..<n {
                    let hue = CGFloat(i) / CGFloat(n)
                    let deep = hue > 0.58 && hue < 0.82
                    let color = dark
                        ? NSColor(hue: hue, saturation: deep ? 0.5 : 0.9, brightness: 1, alpha: 1)
                        : NSColor(hue: hue, saturation: 0.9, brightness: 0.72, alpha: 1)
                    ctx.setFillColor(color.cgColor)
                    let a0 = hue * 2 * .pi, a1 = CGFloat(i + 1) / CGFloat(n) * 2 * .pi + 0.02
                    ctx.move(to: c)
                    ctx.addArc(center: c, radius: r.width, startAngle: a0, endAngle: a1, clockwise: false)
                    ctx.fillPath()
                }
            }
            return true
        }
        img.isTemplate = false
        img.accessibilityDescription = "PeaceMenu"
        return img
    }

    @objc private func separatorClicked(_ sender: NSStatusBarButton) {
        guard let raw = sender.identifier?.rawValue, let id = UUID(uuidString: raw),
              let g = store.config.groups.first(where: { $0.id == id }), let item = separators[id] else { return }
        let menu = NSMenu()
        let title = NSMenuItem(title: g.name, action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        let mode = NSMenuItem(title: "In this profile: \(self.mode(of: id).title)", action: nil, keyEquivalent: "")
        mode.isEnabled = false
        menu.addItem(mode)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        showMenu(menu, on: item)
    }

    // MARK: Watching icons

    /// Every few seconds, reads the state of the icons in folded groups. A change puts a dot on
    /// the group's title and, if asked, brings the icon into the bar for a moment.
    /// Notices icons that weren't there at the last layout (an app launched, or added an icon)
    /// and lays the bar out again, so they land in their group or behind ‹ instead of wherever
    /// macOS put them.
    private func watchNewItems() {
        guard AXIsProcessTrusted(), !layoutRunning, !knownKeys.isEmpty else { return }
        let known = knownKeys, ungrouped = ungroupedMode
        let assigned = Set(store.config.groups.flatMap { $0.items.map(\.key) })
        layoutQueue.async { [weak self] in
            guard let self else { return }
            let items = self.snapshot(quick: true)
            let new = Set(items.filter { !$0.isOurs && !$0.isFixed && !Scanner.isUnhideable($0.key) }.map(\.key)).subtracting(known)
            guard !new.isEmpty else { return }
            // A layout reveals the hidden icons for a moment: only worth it when a new icon is
            // out of place. One in no group belongs between ‹‹ and ‹ (or shown, if the profile
            // shows those); one in a group, in its group.
            let p = Placer(items: items, known: DispatchQueue.main.sync { self.ownWindows })
            let misplaced = new.filter { key in
                if assigned.contains(key) || ungrouped == .always { return true }
                guard let f = p.frame(key), let h = p.frame(Self.hiddenKey) else { return false }
                let behindDeep = p.frame(Self.alwaysKey).map { f.maxX <= $0.minX + 2 } ?? false
                if ungrouped == .off { return !behindDeep }
                return f.minX >= h.maxX - 2 || behindDeep // On demand: between ‹‹ and ‹
            }
            DispatchQueue.main.async {
                self.knownKeys.formUnion(new)
                log("new items: \(new.sorted()), out of place: \(misplaced.sorted())")
                if !misplaced.isEmpty { self.applyLayout(thenHide: self.isHidden) }
            }
        }
    }

    private func checkStates() {
        let mode = store.config.changeSignal
        let folded = store.config.groups.filter { self.mode(of: $0.id) == .onDemand }
        guard mode != .off, !folded.isEmpty, isHidden, AXIsProcessTrusted(), !checkingStates, !layoutRunning else { return }
        checkingStates = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let states = Dictionary(Scanner.scan(quick: true).map { ($0.key, $0.state) }, uniquingKeysWith: { a, _ in a })
            DispatchQueue.main.async {
                guard let self else { return }
                self.checkingStates = false
                for g in folded {
                    // The group may have been opened while the scan ran.
                    guard self.mode(of: g.id) == .onDemand, self.isHidden else { continue }
                    for ref in g.items where !Scanner.isUnhideable(ref.key) {
                        guard let now = states[ref.key] else { continue }
                        defer { self.baseline[ref.key] = now }
                        guard let before = self.baseline[ref.key], before != now else { continue }
                        log("changed in \(g.name): \(ref.name) [\(before)] → [\(now)]")
                        self.changedGroups.insert(g.id)
                        if let item = self.separators[g.id] { self.style(item, for: g) }
                        self.refreshPeaceIcon()
                        // Show the hidden groups for the auto-hide delay: the changed icon is in its group.
                        if self.store.config.changeSignal == .peek && self.isHidden && !self.layoutRunning {
                            self.revealedForUser = true
                            self.setHidden(false)
                        }
                    }
                }
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
            add("⚠︎ Allow Accessibility…", #selector(openAccessibility))
            menu.addItem(.separator())
        }

        menu.addItem(.sectionHeader(title: "Profiles"))
        for p in store.config.profiles {
            add(p.name, #selector(profileFromMenu(_:)), p.id, on: p.id == store.activeProfile?.id)
        }
        menu.addItem(.separator())
        add(isHidden ? "Show Hidden Icons" : "Hide Icons", #selector(toggleHidden))
        add(layoutRunning ? "Arranging…" : "Arrange Menu Bar Now", #selector(relayout), enabled: !layoutRunning)
        add("Settings…", #selector(openSettings), key: ",")
        menu.addItem(.separator())
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        add("PeaceMenu \(version)", nil, enabled: false)
        add("Check for Updates…", #selector(checkForUpdates))
        menu.addItem(.separator())
        add("Quit PeaceMenu", #selector(quit), key: "q")
        return menu
    }

    @objc private func profileFromMenu(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? UUID { activateProfile(id) }
    }
    @objc private func toggleHidden() {
        if isHidden { revealedForUser = true }
        setHidden(!isHidden)
    }
    @objc private func relayout() { applyLayout(thenHide: isHidden) }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func checkForUpdates() {
        NSWorkspace.shared.open(URL(string: "https://github.com/spoulin/peace-menu/releases/latest")!)
    }
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
        var list: [(String, String, NSStatusItem)] = [(Self.mainKey, "PeaceMenu", mainItem), (Self.hiddenKey, "Hidden separator", hiddenItem)]
        if let alwaysItem { list.append((Self.alwaysKey, "Always-hidden zone", alwaysItem)) }
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
        let entries = profileGroups, ungrouped = ungroupedMode, present = unhideable
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            self.layoutQueue.async {
                let failed = Mover.exclusive { self.runLayout(groups: groups, entries: entries, ungrouped: ungrouped, unhideable: present) }
                DispatchQueue.main.async {
                    self.layoutRunning = false
                    self.mainItem.button?.image = self.peaceIcon()
                    if !failed.isEmpty { self.mainItem.button?.toolTip = "PeaceMenu — couldn't move: \(failed.joined(separator: ", "))" }
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
    ///
    ///     [Off …] ‹‹ [On demand groups] ‹ [unhideable] [Always groups] ☮
    private func runLayout(groups: [MenuGroup], entries: [ProfileGroup], ungrouped: GroupMode, unhideable: Set<String>) -> [String] {
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

        // The first time, ‹‹ goes to the far left (a drop where nothing is drawn lands there),
        // so every icon hidden so far stays revealable; then it's stretched for good.
        if !DispatchQueue.main.sync(execute: { alwaysPlaced }), p.windows[Self.alwaysKey] != nil,
           let leftmost = p.windows.keys.filter({ $0 != Self.alwaysKey })
            .compactMap({ k in p.frame(k).map { (k, $0) } })
            .min(by: { $0.1.minX < $1.1.minX })?.0 {
            if p.place(Self.alwaysKey, leftOf: leftmost) {
                DispatchQueue.main.sync { alwaysItem?.length = 10_000; alwaysPlaced = true }
                Thread.sleep(forTimeInterval: 0.3)
                log("layout: ‹‹ placed at the far left")
            }
        }
        let deep = DispatchQueue.main.sync { deepKey }

        // Right to left, starting just left of ☮: the Always groups, ‹, then the On demand ones.
        // Built right to left: a separator listed after its icons ends up left of them.
        let byID = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func block(_ e: ProfileGroup) -> [String] {
            guard let g = byID[e.id] else { return [] }
            let icons = g.items.map(\.key).filter { !Scanner.isUnhideable($0) }
            return g.titleOnLeft ? icons + [Self.sepKey(g.id)] : [Self.sepKey(g.id)] + icons
        }
        let loose = items.filter { !$0.isOurs && !$0.isFixed && !assigned.contains($0.key) && !Scanner.isUnhideable($0.key) }
        var desired: [String] = []
        for e in entries.reversed() where e.mode == .always { desired += block(e) }
        if ungrouped == .always {
            desired += loose.compactMap { it in p.frame(it.key).map { (it.key, $0) } }
                .filter { $0.1.maxX <= mainFrame.minX + 1 }
                .sorted { $0.1.minX > $1.1.minX }.map(\.0)
        }
        desired += unhideable.sorted()
        desired.append(Self.hiddenKey)
        for e in entries.reversed() where e.mode == .onDemand { desired += block(e) }

        log("layout start: \(p.windows.count) of \(items.count) items matched, desired: \(desired)")
        defer { log("layout done, failed: \(p.failed)") }

        var anchor = Self.mainKey
        for key in desired where p.windows[key] != nil {
            if p.place(key, leftOf: anchor) { anchor = key }
        }

        DispatchQueue.main.async { self.knownKeys = Set(items.map(\.key)) }

        // Icons in no group: On demand ones go left of the On demand groups (between ‹‹ and ‹),
        // from between ‹ and ☮ or from behind ‹‹; Off ones go behind ‹‹.
        if ungrouped == .onDemand {
            for it in loose {
                guard let h = p.frame(Self.hiddenKey), let m = p.frame(Self.mainKey), let f = p.frame(it.key) else { continue }
                let shown = f.minX >= h.maxX - 2 && f.maxX <= m.minX + 2
                let deepHidden = deep == Self.alwaysKey && (p.frame(Self.alwaysKey).map { f.maxX <= $0.minX + 2 } ?? false)
                if (shown || deepHidden), p.place(it.key, leftOf: anchor) { anchor = it.key }
            }
        }

        // Off groups (their icons and titles), and Off icons in no group, go behind ‹‹ (behind ‹
        // until ‹‹ is in place).
        let off = Set(entries.filter { $0.mode == .off }.map(\.id))
        var deepKeys = groups.filter { off.contains($0.id) }.flatMap { $0.items.map(\.key) + [Self.sepKey($0.id)] }.filter { !Scanner.isUnhideable($0) }
        if ungrouped == .off { deepKeys += loose.map(\.key) }
        for key in deepKeys {
            guard let sep = p.frame(deep), let f = p.frame(key), f.maxX > sep.minX + 2 else { continue }
            p.hide(key, behind: deep)
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
        var trace: [String] = []
        func describe() -> String {
            "\(frame(key).map { "\(Int($0.minX))…\(Int($0.maxX))" } ?? "?") vs ‹ \(frame(hiddenKey).map { "\(Int($0.minX))" } ?? "?")"
        }
        for _ in 0..<3 {
            if isBehind() { return true }
            let before = describe()
            let moved = Mover.move(w, leftOf: a)
            trace.append("\(before) → moved \(moved) → \(describe())")
        }
        if isBehind() { return true }
        log("hide \(names[key] ?? key) failed: \(trace.joined(separator: " ; "))")
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

extension NSColor {
    /// "#RRGGBB" or "RRGGBB".
    convenience init?(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                  blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }

    var hex: String? {
        guard let c = usingColorSpace(.sRGB) else { return nil }
        let r = Int((c.redComponent * 255).rounded()), g = Int((c.greenComponent * 255).rounded()), b = Int((c.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

extension NSImage {
    /// The image's shape filled with `color` (no longer a template, so the menu bar keeps the color).
    func tinted(_ color: NSColor) -> NSImage {
        let img = NSImage(size: size, flipped: false) { r in
            self.draw(in: r)
            color.set()
            r.fill(using: .sourceAtop)
            return true
        }
        img.isTemplate = false
        return img
    }
}

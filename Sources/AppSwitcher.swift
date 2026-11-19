import AppKit

/// The apps of the Dock in a grid in the middle of the screen, the ones used most first, to
/// pick one with the keyboard: arrows and Return, or the first letters of its name.
///
/// Like ⌘⇥: keep the shortcut's modifier down and press its key again to move to the next app;
/// letting go of the modifier then opens it. A single press leaves the grid open for the arrows.
/// Escape, a click outside or the shortcut's key after letting go of the modifier close it.
/// ⌘Q quits the selected app and ⌥⌘Q forces it to quit, as in ⌘⇥; the grid stays open.
///
/// On several screens, each shows the same grid: the panel on the screen with the pointer takes
/// the keyboard, the others follow it, and the pointer works in all of them.
final class AppSwitcher {
    static let shared = AppSwitcher()

    private let state = SwitcherState()
    /// One per screen, kept for the next time.
    private var panels: [SwitcherPanel] = []
    /// The ones showing now; `keyPanel` is one of them.
    private var shown: [SwitcherPanel] = []
    private var keyPanel: SwitcherPanel?
    private var screens: SwitcherScreens = .mouse
    private var opening = false
    /// The shortcut's modifiers, while they are still held from the press that opened the grid.
    private var heldModifiers: NSEvent.ModifierFlags = []
    /// The shortcut's key was pressed again while they were held: letting go chooses.
    private var advanced = false
    private var modifierTimer: Timer?
    var isOpen: Bool { keyPanel?.isVisible == true }

    private init() {
        state.onChange = { [weak self] in self?.shown.forEach { $0.contentView?.needsDisplay = true } }
        // An app quit (from the grid or elsewhere) while it's open: the grid follows.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.reload()
        }
    }

    /// The shortcut was pressed: opens the grid; with it open and the modifier still held, moves
    /// to the next app; otherwise closes it.
    func press(_ shortcut: Shortcut?, on screens: SwitcherScreens) {
        if isOpen {
            if !heldModifiers.isEmpty {
                advanced = true
                state.move(by: 1)
            } else {
                close()
            }
            return
        }
        guard !opening else { return }
        opening = true
        heldModifiers = shortcut?.flags ?? []
        advanced = false
        self.screens = screens
        loadApps { self.show($0) }
    }

    /// The Dock's apps, read off the main thread.
    private func loadApps(_ then: @escaping ([DockApp]) -> Void) {
        let trusted = AXIsProcessTrusted()
        DispatchQueue.global(qos: .userInteractive).async {
            var apps = trusted ? Apps.dockApps() : []
            // Without Accessibility, or a Dock that didn't answer: the running apps.
            if apps.isEmpty {
                apps = Apps.running().compactMap { a in
                    guard let url = a.url else { return nil }
                    return DockApp(name: a.name, bundleID: a.bundleID ?? url.path, url: url, badge: nil, isRunning: true)
                }
            }
            DispatchQueue.main.async { then(apps) }
        }
    }

    /// Reads the apps again, for an app that quit: it leaves the grid, or turns grey if it's
    /// kept in the Dock. The selection stays in place.
    private func reload() {
        guard isOpen else { return }
        // The Dock takes a moment to drop the app.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.loadApps { apps in
                guard self.isOpen, !apps.isEmpty else { return }
                self.state.reload(self.order(apps))
                self.views.forEach { $0.layOut() }
            }
        }
    }

    private func quit(_ app: DockApp?, force: Bool) {
        let running = app.map { NSRunningApplication.runningApplications(withBundleIdentifier: $0.bundleID) } ?? []
        guard !running.isEmpty else { NSSound.beep(); return }
        for r in running {
            let done = force ? r.forceTerminate() : r.terminate()
            log("\(force ? "force quit" : "quit") \(r.localizedName ?? app?.name ?? "?"): \(done)")
        }
    }

    func close() {
        modifierTimer?.invalidate()
        modifierTimer = nil
        heldModifiers = []
        let panels = shown
        shown = []
        keyPanel = nil
        panels.forEach { $0.orderOut(nil) }
    }

    private var views: [AppSwitcherView] { shown.compactMap { $0.contentView as? AppSwitcherView } }

    private func choose(_ app: DockApp?) {
        close()
        if let app { Apps.open(app.url) }
    }

    private func show(_ apps: [DockApp]) {
        opening = false
        guard !apps.isEmpty else { NSSound.beep(); return }
        let mouse = NSEvent.mouseLocation
        let mouseScreen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let targets: [NSScreen]
        switch screens {
        case .mouse: targets = mouseScreen.map { [$0] } ?? []
        // The first screen is the one with the menu bar in System Settings › Displays.
        case .main: targets = Array(NSScreen.screens.prefix(1))
        case .all: targets = NSScreen.screens
        }
        guard !targets.isEmpty else { return }
        while panels.count < targets.count { panels.append(makePanel()) }
        shown = Array(panels.prefix(targets.count))
        // The keyboard goes to the screen with the pointer, if the grid is there.
        let keyIndex = targets.firstIndex { $0 == mouseScreen } ?? 0
        state.show(order(apps), front: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        for (i, (panel, screen)) in zip(shown, targets).enumerated() {
            panel.takesKeyboard = i == keyIndex
            panel.setFrame(screen.frame, display: false)
            (panel.contentView as? AppSwitcherView)?.show(within: screen.visibleFrame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY))
            if i != keyIndex { panel.orderFrontRegardless() }
        }
        let panel = shown[keyIndex]
        keyPanel = panel
        // Key, so the arrows reach it; a non-activating panel leaves the front app active.
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(panel.contentView)
        // Letting go of the modifier: there is no hot key event for it, so watch for it.
        if !heldModifiers.isEmpty {
            modifierTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in self?.checkModifiers() }
        }
    }

    private func makePanel() -> SwitcherPanel {
        let p = SwitcherPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .popUpMenu
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        let v = AppSwitcherView(state: state)
        v.autoresizingMask = [.width, .height]
        v.onChoose = { [weak self] app in self?.choose(app) }
        v.onQuit = { [weak self] app, force in self?.quit(app, force: force) }
        p.contentView = v
        // Only the panel with the keyboard closes the grid when it loses it; the others can't
        // take it, so a click in them leaves it where it is.
        p.onResignKey = { [weak self, weak p] in if p === self?.keyPanel { self?.close() } }
        p.onFlagsChanged = { [weak self] flags in self?.checkModifiers(flags) }
        return p
    }

    /// From the panel's flagsChanged, or polled: the modifiers held now.
    private func checkModifiers(_ now: NSEvent.ModifierFlags = NSEvent.modifierFlags) {
        guard !heldModifiers.isEmpty, now.intersection(heldModifiers).isEmpty else { return }
        heldModifiers = []
        modifierTimer?.invalidate()
        modifierTimer = nil
        if advanced { choose(state.selected) }
    }

    /// The apps with a badge first, then the others; in each, the ones used most first (Usage),
    /// then running before kept, in Dock order.
    private func order(_ apps: [DockApp]) -> [DockApp] {
        let score = Usage.scores()
        return apps.enumerated().sorted { a, b in
            if (a.element.badge != nil) != (b.element.badge != nil) { return a.element.badge != nil }
            let sa = score[a.element.bundleID] ?? 0, sb = score[b.element.bundleID] ?? 0
            if sa != sb { return sa > sb }
            if a.element.isRunning != b.element.isRunning { return a.element.isRunning }
            return a.offset < b.offset
        }.map(\.element)
    }
}

/// A full-screen, transparent panel that takes the keyboard without activating PeaceMenu.
final class SwitcherPanel: NSPanel {
    var onResignKey: (() -> Void)?
    var onFlagsChanged: ((NSEvent.ModifierFlags) -> Void)?
    /// False for the copies of the grid on the other screens.
    var takesKeyboard = true
    override var canBecomeKey: Bool { takesKeyboard }
    override func flagsChanged(with event: NSEvent) { onFlagsChanged?(event.modifierFlags) }
    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}

/// What every screen's grid shows: the apps, the selection and what was typed.
final class SwitcherState {
    private(set) var apps: [DockApp] = []
    var selection = 0 { didSet { if selection != oldValue { onChange?() } } }
    var selected: DockApp? { apps.indices.contains(selection) ? apps[selection] : nil }
    var typed = "" { didSet { if typed != oldValue { onChange?() } } }
    var lastTyped = Date.distantPast
    /// Redraws the grids.
    var onChange: (() -> Void)?

    /// The first app that isn't the front one selected (as in ⌘⇥).
    func show(_ apps: [DockApp], front: String?) {
        self.apps = apps
        selection = apps.firstIndex { $0.bundleID != front } ?? 0
        typed = ""
    }

    /// New apps for the same grid: the selected app stays selected; if it's gone, the app that
    /// took its place is.
    func reload(_ apps: [DockApp]) {
        let id = selected?.bundleID
        self.apps = apps
        selection = apps.firstIndex { $0.bundleID == id } ?? min(selection, apps.count - 1)
    }

    /// Moves the selection along the grid, wrapping at the ends.
    func move(by step: Int) {
        guard !apps.isEmpty else { return }
        selection = ((selection + step) % apps.count + apps.count) % apps.count
    }
}

/// One screen's grid, laid out for that screen.
final class AppSwitcherView: NSView {
    var onChoose: ((DockApp?) -> Void)?
    var onQuit: ((DockApp?, Bool) -> Void)?
    private let state: SwitcherState
    private var visible: CGRect = .zero
    private var apps: [DockApp] { state.apps }
    private var selection: Int {
        get { state.selection }
        set { state.selection = newValue }
    }
    private var selected: DockApp? { state.selected }
    private var typed: String {
        get { state.typed }
        set { state.typed = newValue }
    }
    private var box: CGRect = .zero
    private var columns = 8
    /// Where each app sits. The apps with a badge have their own rows, above a thin line.
    private var slots: [(row: Int, col: Int)] = []
    private var rows = 0
    /// The first row below the line, if there is one.
    private var restRow: Int?
    private let divider: CGFloat = 15

    private let cell = CGSize(width: 96, height: 100)
    private let iconSize: CGFloat = 56
    private let padding: CGFloat = 18
    private let footer: CGFloat = 26
    private static var icons: [String: NSImage] = [:]

    init(state: SwitcherState) {
        self.state = state
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }

    /// Centred in `visible`.
    func show(within visible: CGRect) {
        self.visible = visible
        layOut()
    }

    /// After the apps changed.
    func layOut() {
        let fit = max(1, Int((visible.width - padding * 2 - 40) / cell.width))
        columns = max(1, min(8, apps.count, fit))
        let badged = apps.prefix { $0.badge != nil }.count
        let badgedRows = (badged + columns - 1) / columns
        restRow = badged > 0 && badged < apps.count ? badgedRows : nil
        slots = apps.indices.map { i in
            i < badged || restRow == nil ? (i / columns, i % columns) : (badgedRows + (i - badged) / columns, (i - badged) % columns)
        }
        rows = (slots.last?.row ?? 0) + 1
        // Wide enough for the keys at the bottom.
        let size = CGSize(width: max(CGFloat(columns) * cell.width, footerLabel(Self.hint).size().width) + padding * 2,
                          height: CGFloat(rows) * cell.height + padding * 2 + footer + (restRow == nil ? 0 : divider))
        box = CGRect(x: (visible.midX - size.width / 2).rounded(), y: (visible.midY - size.height / 2).rounded(),
                     width: size.width, height: size.height)
        needsDisplay = true
    }

    private func frame(of index: Int) -> CGRect {
        let (row, col) = slots[index]
        let below = restRow.map { row >= $0 ? divider : 0 } ?? 0
        return CGRect(x: box.minX + padding + CGFloat(col) * cell.width,
                      y: box.maxY - padding - CGFloat(row + 1) * cell.height - below,
                      width: cell.width, height: cell.height)
    }

    /// ↑ or ↓: the app in the same column of the next row (wrapping), or the last one of a
    /// shorter row.
    private func moveRow(by step: Int) {
        guard rows > 1 else { return }
        let (row, col) = slots[selection]
        let target = ((row + step) % rows + rows) % rows
        let inRow = apps.indices.filter { slots[$0].row == target }
        if let i = inRow.first(where: { slots[$0].col == col }) ?? inRow.last { selection = i }
    }

    private func index(at p: CGPoint) -> Int? { apps.indices.first { frame(of: $0).contains(p) } }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case 12 where event.modifierFlags.contains(.command):           // ⌘Q quits, ⌥⌘Q forces
            onQuit?(selected, event.modifierFlags.contains(.option))
        case 53: onChoose?(nil)                                         // Escape
        case 36, 76: onChoose?(selected)                                // Return, Enter
        case 123: state.move(by: -1)                                    // ←
        case 124: state.move(by: 1)                                     // →
        case 48: state.move(by: event.modifierFlags.contains(.shift) ? -1 : 1) // Tab
        case 125: moveRow(by: 1)                                        // ↓
        case 126: moveRow(by: -1)                                       // ↑
        case 51:                                                        // Delete: one letter less
            if !typed.isEmpty { typed.removeLast(); find() }
        default:
            guard let s = event.charactersIgnoringModifiers, !s.isEmpty,
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  s.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(.whitespaces).contains($0) }) else {
                super.keyDown(with: event)
                return
            }
            // Letters typed within a second add up, as in Finder.
            if Date().timeIntervalSince(state.lastTyped) > 1 { typed = "" }
            state.lastTyped = Date()
            typed += s
            find()
        }
    }

    /// Selects the first app whose name starts with what was typed, else one that contains it.
    private func find() {
        guard !typed.isEmpty else { return }
        let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        if let i = apps.firstIndex(where: { $0.name.range(of: typed, options: opts.union(.anchored)) != nil })
            ?? apps.firstIndex(where: { $0.name.range(of: typed, options: opts) != nil }) {
            selection = i
        } else {
            NSSound.beep()
        }
    }

    // MARK: Pointer

    override func mouseMoved(with event: NSEvent) {
        if let i = index(at: convert(event.locationInWindow, from: nil)) { selection = i }
    }

    override func mouseDown(with event: NSEvent) {
        // An app: opens it. Elsewhere in the grid: nothing. Outside: closes.
        let p = convert(event.locationInWindow, from: nil)
        if let i = index(at: p) { onChoose?(apps[i]) } else if !box.contains(p) { onChoose?(nil) }
    }

    override func rightMouseDown(with event: NSEvent) { onChoose?(nil) }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard !apps.isEmpty, let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 24, color: NSColor.black.withAlphaComponent(0.45).cgColor)
        NSColor.black.withAlphaComponent(0.86).setFill()
        NSBezierPath(roundedRect: box, xRadius: 20, yRadius: 20).fill()
        ctx.restoreGState()

        // The line under the apps with a badge.
        if let restRow {
            let y = box.maxY - padding - CGFloat(restRow) * cell.height - divider / 2
            NSColor.white.withAlphaComponent(0.18).setFill()
            NSRect(x: box.minX + padding + 8, y: y.rounded() - 0.5, width: box.width - padding * 2 - 16, height: 1).fill()
        }
        for (i, app) in apps.enumerated() { draw(app, in: frame(of: i), selected: i == selection) }
        drawFooter()
    }

    private func draw(_ app: DockApp, in cell: CGRect, selected: Bool) {
        if selected {
            NSColor.white.withAlphaComponent(0.2).setFill()
            NSBezierPath(roundedRect: cell.insetBy(dx: 4, dy: 4), xRadius: 12, yRadius: 12).fill()
        }
        let rect = CGRect(x: cell.midX - iconSize / 2, y: cell.maxY - 10 - iconSize, width: iconSize, height: iconSize)
        // An app that isn't running (only kept in the Dock) is greyed out.
        if app.isRunning {
            icon(for: app).draw(in: rect)
        } else {
            greyIcon(for: app).draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.6)
        }
        if let badge = app.badge { drawBadge(badge, topRight: CGPoint(x: rect.maxX + 4, y: rect.maxY + 2)) }
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail
        let name = NSAttributedString(string: app.name, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: selected ? .semibold : .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(selected ? 1 : 0.75),
            .paragraphStyle: style,
        ])
        name.draw(with: CGRect(x: cell.minX + 6, y: cell.minY + 8, width: cell.width - 12, height: 16), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    private func drawBadge(_ label: String, topRight: CGPoint) {
        let text = NSAttributedString(string: label, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold), .foregroundColor: NSColor.white])
        let t = text.size()
        let h: CGFloat = 18, w = max(h, ceil(t.width) + 9)
        let r = CGRect(x: topRight.x - w, y: topRight.y - h, width: w, height: h)
        NSColor.systemRed.setFill()
        NSBezierPath(roundedRect: r, xRadius: h / 2, yRadius: h / 2).fill()
        text.draw(at: CGPoint(x: r.midX - t.width / 2, y: r.midY - t.height / 2))
    }

    /// What was typed, or the keys to use.
    private static let hint = ["←→↑↓ move", "↩ open", "type a name", "⌘Q quit", "⌥⌘Q force quit", "esc close"]
        .joined(separator: "\u{2003}·\u{2003}")  // em spaces around the dots

    private func footerLabel(_ text: String, bright: Bool = false) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(bright ? 0.9 : 0.5),
        ])
    }

    private func drawFooter() {
        let label = typed.isEmpty ? footerLabel(Self.hint) : footerLabel("“\(typed)”", bright: true)
        let s = label.size()
        label.draw(at: CGPoint(x: box.midX - s.width / 2, y: box.minY + padding - 4))
    }

    private func icon(for app: DockApp) -> NSImage {
        if let cached = Self.icons[app.url.path] { return cached }
        let img = NSWorkspace.shared.icon(forFile: app.url.path)
        Self.icons[app.url.path] = img
        return img
    }

    /// The icon in black and white.
    private func greyIcon(for app: DockApp) -> NSImage {
        let key = "grey:" + app.url.path
        if let cached = Self.icons[key] { return cached }
        let source = icon(for: app)
        let size = NSSize(width: iconSize * 2, height: iconSize * 2)
        guard let cg = source.cgImage(forProposedRect: nil, context: nil, hints: [.ctm: AffineTransform(scale: size.width / source.size.width)]),
              let filter = CIFilter(name: "CIColorControls") else { return source }
        filter.setValue(CIImage(cgImage: cg), forKey: kCIInputImageKey)
        filter.setValue(0, forKey: kCIInputSaturationKey)
        guard let out = filter.outputImage, let grey = CIContext().createCGImage(out, from: out.extent) else { return source }
        let img = NSImage(cgImage: grey, size: size)
        Self.icons[key] = img
        return img
    }
}

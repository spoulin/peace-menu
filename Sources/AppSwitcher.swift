import AppKit

/// The apps of the Dock in a grid in the middle of the screen, the ones used most first, to
/// pick one with the keyboard: arrows and Return, or the first letters of its name.
///
/// Like ⌘⇥: keep the shortcut's modifier down and press its key again to move to the next app;
/// letting go of the modifier then opens it. A single press leaves the grid open for the arrows.
/// Escape, a click outside or the shortcut's key after letting go of the modifier close it.
final class AppSwitcher {
    static let shared = AppSwitcher()

    private var panel: SwitcherPanel?
    private var view: AppSwitcherView?
    private var opening = false
    /// The shortcut's modifiers, while they are still held from the press that opened the grid.
    private var heldModifiers: NSEvent.ModifierFlags = []
    /// The shortcut's key was pressed again while they were held: letting go chooses.
    private var advanced = false
    private var modifierTimer: Timer?
    var isOpen: Bool { panel?.isVisible == true }

    /// The shortcut was pressed: opens the grid; with it open and the modifier still held, moves
    /// to the next app; otherwise closes it.
    func press(_ shortcut: Shortcut?) {
        if isOpen {
            if !heldModifiers.isEmpty {
                advanced = true
                view?.move(by: 1)
            } else {
                close()
            }
            return
        }
        guard !opening else { return }
        opening = true
        heldModifiers = shortcut?.flags ?? []
        advanced = false
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
            DispatchQueue.main.async { self.show(apps) }
        }
    }

    func close() {
        modifierTimer?.invalidate()
        modifierTimer = nil
        heldModifiers = []
        panel?.orderOut(nil)
    }

    private func choose(_ app: DockApp?) {
        close()
        if let app { Apps.open(app.url) }
    }

    private func show(_ apps: [DockApp]) {
        opening = false
        guard !apps.isEmpty else { NSSound.beep(); return }
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else { return }
        if panel == nil {
            let p = SwitcherPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = .popUpMenu
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
            let v = AppSwitcherView(frame: NSRect(origin: .zero, size: screen.frame.size))
            v.autoresizingMask = [.width, .height]
            v.onChoose = { [weak self] app in self?.choose(app) }
            p.contentView = v
            p.onResignKey = { [weak self] in self?.close() }
            p.onFlagsChanged = { [weak self] flags in self?.checkModifiers(flags) }
            panel = p
            view = v
        }
        guard let panel, let view else { return }
        panel.setFrame(screen.frame, display: false)
        view.show(order(apps), front: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                  within: screen.visibleFrame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY))
        // Key, so the arrows reach it; a non-activating panel leaves the front app active.
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(view)
        // Letting go of the modifier: there is no hot key event for it, so watch for it.
        if !heldModifiers.isEmpty {
            modifierTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in self?.checkModifiers() }
        }
    }

    /// From the panel's flagsChanged, or polled: the modifiers held now.
    private func checkModifiers(_ now: NSEvent.ModifierFlags = NSEvent.modifierFlags) {
        guard !heldModifiers.isEmpty, now.intersection(heldModifiers).isEmpty else { return }
        heldModifiers = []
        modifierTimer?.invalidate()
        modifierTimer = nil
        if advanced { choose(view?.selected) }
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
    override var canBecomeKey: Bool { true }
    override func flagsChanged(with event: NSEvent) { onFlagsChanged?(event.modifierFlags) }
    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}

final class AppSwitcherView: NSView {
    var onChoose: ((DockApp?) -> Void)?
    private var apps: [DockApp] = []
    private var selection = 0
    var selected: DockApp? { apps.indices.contains(selection) ? apps[selection] : nil }
    private var typed = ""
    private var lastTyped = Date.distantPast
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

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }

    /// Centred in `visible`, the first app that isn't the front one selected (as in ⌘⇥).
    func show(_ apps: [DockApp], front: String?, within visible: CGRect) {
        self.apps = apps
        selection = apps.firstIndex { $0.bundleID != front } ?? 0
        typed = ""
        let fit = max(1, Int((visible.width - padding * 2 - 40) / cell.width))
        columns = max(1, min(8, apps.count, fit))
        let badged = apps.prefix { $0.badge != nil }.count
        let badgedRows = (badged + columns - 1) / columns
        restRow = badged > 0 && badged < apps.count ? badgedRows : nil
        slots = apps.indices.map { i in
            i < badged || restRow == nil ? (i / columns, i % columns) : (badgedRows + (i - badged) / columns, (i - badged) % columns)
        }
        rows = (slots.last?.row ?? 0) + 1
        let size = CGSize(width: CGFloat(columns) * cell.width + padding * 2,
                          height: CGFloat(rows) * cell.height + padding * 2 + footer + (restRow == nil ? 0 : divider))
        box = CGRect(x: (visible.midX - size.width / 2).rounded(), y: (visible.midY - size.height / 2).rounded(),
                     width: size.width, height: size.height)
        needsDisplay = true
    }

    /// Moves the selection along the grid, wrapping at the ends.
    func move(by step: Int) {
        guard !apps.isEmpty else { return }
        selection = ((selection + step) % apps.count + apps.count) % apps.count
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
        needsDisplay = true
    }

    private func index(at p: CGPoint) -> Int? { apps.indices.first { frame(of: $0).contains(p) } }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case 53: onChoose?(nil)                                         // Escape
        case 36, 76: onChoose?(selected)                                // Return, Enter
        case 123: move(by: -1)                                          // ←
        case 124: move(by: 1)                                           // →
        case 48: move(by: event.modifierFlags.contains(.shift) ? -1 : 1) // Tab
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
            if Date().timeIntervalSince(lastTyped) > 1 { typed = "" }
            lastTyped = Date()
            typed += s
            find()
        }
    }

    /// Selects the first app whose name starts with what was typed, else one that contains it.
    private func find() {
        defer { needsDisplay = true }
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
        if let i = index(at: convert(event.locationInWindow, from: nil)), i != selection {
            selection = i
            needsDisplay = true
        }
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
    private func drawFooter() {
        let text = typed.isEmpty ? "Arrows to move · Return to open · type a name · Esc to close" : "“\(typed)”"
        let label = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(typed.isEmpty ? 0.5 : 0.9),
        ])
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

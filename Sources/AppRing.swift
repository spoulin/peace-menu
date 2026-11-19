import AppKit

/// The apps of the Dock on a ring around the pointer, like the action wheels of console games.
///
/// Hold the shortcut, point toward an app and let go: it comes to the front, or opens. A quick
/// press leaves the ring open: then click an app. Letting go in the middle, a click in the
/// middle or outside, Escape or the shortcut again close it.
final class AppRing {
    static let shared = AppRing()

    private var panel: RingPanel?
    private var view: AppRingView?
    private var openedAt = Date.distantPast
    private var opening = false
    var isOpen: Bool { panel?.isVisible == true }

    /// The shortcut went down: opens the ring, or closes it when it's already open.
    func press() {
        if isOpen { close(); return }
        guard !opening else { return }
        opening = true
        openedAt = Date()
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

    /// The shortcut was let go: a hold chooses what's under the pointer; a quick press keeps
    /// the ring open for a click.
    func release() {
        guard let view, isOpen, view.holding else { return }
        if Date().timeIntervalSince(openedAt) < 0.3 && view.hovered == nil {
            view.holding = false
            view.needsDisplay = true
            return
        }
        let chosen = view.hovered
        close()
        if let chosen { Apps.open(chosen.url) }
    }

    func close() {
        panel?.orderOut(nil)
        view?.apps = []
    }

    private func show(_ apps: [DockApp]) {
        opening = false
        guard !apps.isEmpty else { NSSound.beep(); return }
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else { return }
        if panel == nil {
            let p = RingPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = .popUpMenu
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
            let v = AppRingView(frame: NSRect(origin: .zero, size: screen.frame.size))
            v.autoresizingMask = [.width, .height]
            v.onChoose = { [weak self] app in
                self?.close()
                if let app { Apps.open(app.url) }
            }
            p.contentView = v
            p.onEscape = { [weak self] in self?.close() }
            p.onResignKey = { [weak self] in self?.close() }
            panel = p
            view = v
        }
        guard let panel, let view else { return }
        panel.setFrame(screen.frame, display: false)
        let local = CGPoint(x: mouse.x - screen.frame.minX, y: mouse.y - screen.frame.minY)
        // Kept inside the visible part of the screen (below the menu bar, beside the Dock).
        let visible = screen.visibleFrame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        view.show(apps, at: local, within: visible)
        panel.alphaValue = 0
        // Key, so Escape reaches it; a non-activating panel leaves the front app active.
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.08; panel.animator().alphaValue = 1 }
    }
}

/// A full-screen, transparent panel that takes the keyboard without activating PeaceMenu.
final class RingPanel: NSPanel {
    var onEscape: (() -> Void)?
    var onResignKey: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) }
    }
    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}

final class AppRingView: NSView {
    var apps: [DockApp] = [] { didSet { layoutRings() } }
    /// The shortcut is still held down.
    var holding = true
    private(set) var hovered: DockApp?
    var onChoose: ((DockApp?) -> Void)?

    /// Each ring: its apps, its band (inner and outer radius), where the icons sit and their size.
    private struct Ring { var apps: [DockApp]; var inner: CGFloat; var outer: CGFloat; var mid: CGFloat; var icon: CGFloat }
    private var rings: [Ring] = []
    private var center: CGPoint = .zero
    private let hole: CGFloat = 46
    private static var icons: [String: NSImage] = [:]

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }

    func show(_ apps: [DockApp], at point: CGPoint, within visible: CGRect) {
        holding = true
        hovered = nil
        self.apps = apps
        let r = (rings.last?.outer ?? hole) + 24
        center = CGPoint(x: min(max(point.x, visible.minX + r), max(visible.minX + r, visible.maxX - r)),
                         y: min(max(point.y, visible.minY + r), max(visible.minY + r, visible.maxY - r)))
        updateHover(at: point)
        needsDisplay = true
    }

    /// The running apps first, then the ones only kept in the Dock, each in Dock order: up to
    /// 12 on the first ring, the rest on rings further out. Every app keeps its place, so the
    /// hand learns where it is.
    private func layoutRings() {
        var rest = apps.filter(\.isRunning) + apps.filter { !$0.isRunning }
        let icon: CGFloat = 40, gap: CGFloat = 14
        rings = []
        var inner = hole
        while !rest.isEmpty {
            var mid = inner + icon / 2 + 10
            if rings.isEmpty { mid = max(mid, CGFloat(min(rest.count, 12)) * (icon + gap) / (2 * .pi)) }
            let fits = rings.isEmpty ? min(12, rest.count) : max(1, Int(2 * .pi * mid / (icon + gap)))
            let n = min(fits, rest.count)
            let outer = mid + icon / 2 + 12
            rings.append(Ring(apps: Array(rest.prefix(n)), inner: inner, outer: outer, mid: mid, icon: icon))
            rest.removeFirst(n)
            inner = outer
        }
    }

    // MARK: Pointer

    override func mouseMoved(with event: NSEvent) { updateHover(at: convert(event.locationInWindow, from: nil)) }
    override func mouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseDown(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
        onChoose?(hovered)  // nothing under the pointer: just closes
    }
    override func rightMouseDown(with event: NSEvent) { onChoose?(nil) }

    private func updateHover(at p: CGPoint) {
        let dx = p.x - center.x, dy = p.y - center.y
        let distance = hypot(dx, dy)
        var target: DockApp?
        if let ring = rings.first(where: { distance >= $0.inner && distance < $0.outer + ($0.inner == rings.last?.inner ? 40 : 0) }) {
            // Angle measured clockwise from the top.
            var angle = atan2(dx, dy)
            if angle < 0 { angle += 2 * .pi }
            let slice = 2 * .pi / CGFloat(ring.apps.count)
            target = ring.apps[Int((angle + slice / 2) / slice) % ring.apps.count]
        }
        if target?.bundleID != hovered?.bundleID {
            hovered = target
            needsDisplay = true
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard !rings.isEmpty, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let outer = rings.last!.outer
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 24, color: NSColor.black.withAlphaComponent(0.45).cgColor)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.86).cgColor)
        ctx.fillEllipse(in: CGRect(x: center.x - outer, y: center.y - outer, width: outer * 2, height: outer * 2))
        ctx.restoreGState()
        // A faint line between the rings.
        for ring in rings.dropFirst() {
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.12).cgColor)
            ctx.setLineWidth(1)
            ctx.strokeEllipse(in: CGRect(x: center.x - ring.inner, y: center.y - ring.inner, width: ring.inner * 2, height: ring.inner * 2))
        }
        for ring in rings { draw(ring, ctx) }
        drawCenter()
    }

    private func draw(_ ring: Ring, _ ctx: CGContext) {
        let slice = 2 * .pi / CGFloat(ring.apps.count)
        let mid = ring.mid
        for (i, app) in ring.apps.enumerated() {
            let angle = CGFloat(i) * slice
            let spot = CGPoint(x: center.x + sin(angle) * mid, y: center.y + cos(angle) * mid)
            let s = ring.icon
            let rect = CGRect(x: spot.x - s / 2, y: spot.y - s / 2 + 2, width: s, height: s)
            if app.bundleID == hovered?.bundleID {
                NSColor.controlAccentColor.setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: -7, dy: -9).offsetBy(dx: 0, dy: -2), xRadius: 12, yRadius: 12).fill()
            }
            icon(for: app).draw(in: rect, from: .zero, operation: .sourceOver, fraction: app.isRunning ? 1 : 0.8)
            // A running app has a dot under it, as in the Dock.
            if app.isRunning {
                ctx.setFillColor(NSColor.white.withAlphaComponent(0.85).cgColor)
                ctx.fillEllipse(in: CGRect(x: spot.x - 2, y: rect.minY - 6, width: 4, height: 4))
            }
            if let badge = app.badge { drawBadge(badge, topRight: CGPoint(x: rect.maxX + 3, y: rect.maxY + 3)) }
        }
    }

    private func drawBadge(_ label: String, topRight: CGPoint) {
        let text = NSAttributedString(string: label, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold), .foregroundColor: NSColor.white])
        let t = text.size()
        let h: CGFloat = 16, w = max(h, ceil(t.width) + 8)
        let r = CGRect(x: topRight.x - w, y: topRight.y - h, width: w, height: h)
        NSColor.systemRed.setFill()
        NSBezierPath(roundedRect: r, xRadius: h / 2, yRadius: h / 2).fill()
        text.draw(at: CGPoint(x: r.midX - t.width / 2, y: r.midY - t.height / 2))
    }

    /// The name of the app under the pointer, or how to close.
    private func drawCenter() {
        let text = hovered?.name ?? (holding ? "Let go to close" : "Esc to close")
        let label = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: hovered == nil ? 9 : 12, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(hovered == nil ? 0.6 : 1),
        ])
        let s = label.size()
        if s.width < hole * 2 - 8 {
            label.draw(at: CGPoint(x: center.x - s.width / 2, y: center.y - s.height / 2))
        } else {
            // Too wide for the middle: just above the ring, on a dark pill.
            let top = (rings.last?.outer ?? hole) + 10
            let pill = CGRect(x: center.x - s.width / 2 - 8, y: center.y + top, width: s.width + 16, height: s.height + 6)
            NSColor.black.withAlphaComponent(0.78).setFill()
            NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
            label.draw(at: CGPoint(x: pill.minX + 8, y: pill.minY + 3))
        }
    }

    private func icon(for app: DockApp) -> NSImage {
        if let cached = Self.icons[app.url.path] { return cached }
        let img = NSWorkspace.shared.icon(forFile: app.url.path)
        Self.icons[app.url.path] = img
        return img
    }
}

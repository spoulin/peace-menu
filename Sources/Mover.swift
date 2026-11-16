import AppKit
import CoreGraphics

// Private window server calls, the same ones Ice uses. They see every menu bar item window,
// including items macOS doesn't draw because the bar is full.
private typealias CGSConnectionID = Int32
@_silgen_name("CGSMainConnectionID") private func CGSMainConnectionID() -> CGSConnectionID
@_silgen_name("CGSGetWindowCount") private func CGSGetWindowCount(_ cid: CGSConnectionID, _ target: CGSConnectionID, _ count: inout Int32) -> CGError
@_silgen_name("CGSGetProcessMenuBarWindowList") private func CGSGetProcessMenuBarWindowList(
    _ cid: CGSConnectionID, _ target: CGSConnectionID, _ count: Int32,
    _ list: UnsafeMutablePointer<CGWindowID>, _ outCount: inout Int32) -> CGError
@_silgen_name("CGSSetConnectionProperty") private func CGSSetConnectionProperty(_ cid: CGSConnectionID, _ target: CGSConnectionID, _ key: CFString, _ value: CFTypeRef) -> CGError
@_silgen_name("CGSGetScreenRectForWindow") private func CGSGetScreenRectForWindow(_ cid: CGSConnectionID, _ wid: CGWindowID, _ rect: inout CGRect) -> CGError

/// Moves menu bar items with mouse events aimed at the items' windows, as Ice does: a Command
/// mouse-down on the item's window, then a mouse-up on the edge of the destination item's window.
/// The moved item doesn't need to be drawn, but the destination does.
enum Mover {
    private static let windowIDField = CGEventField(rawValue: 0x33)!

    /// Every menu bar item window (one per item and per display).
    static func menuBarWindows() -> [CGWindowID] {
        let cid = CGSMainConnectionID()
        var count: Int32 = 0
        guard CGSGetWindowCount(cid, 0, &count) == .success, count > 0 else { return [] }
        var list = [CGWindowID](repeating: 0, count: Int(count))
        var real: Int32 = 0
        guard CGSGetProcessMenuBarWindowList(cid, 0, count, &list, &real) == .success else { return [] }
        return Array(list[..<Int(real)])
    }

    /// Where the window server has a window right now. No lag, unlike Accessibility.
    static func frame(of window: CGWindowID) -> CGRect? {
        var r = CGRect.zero
        guard CGSGetScreenRectForWindow(CGSMainConnectionID(), window, &r) == .success, r.width > 0 else { return nil }
        return r
    }

    /// Finds each item's window. On macOS 26 every item window belongs to Control Center, so
    /// windows can't be matched to apps by owner. Instead: Accessibility reports the items on the
    /// display where the menu bar is active, in the same left-to-right order as that display's
    /// windows. Items whose position matches a window exactly anchor the match; between two
    /// anchors, the remaining items and windows are paired in order when their counts agree.
    /// (Items macOS doesn't draw still have a window, just not where Accessibility says.)
    /// `known` gives the windows of PeaceMenu's own items, noted when they were created.
    static func attachWindows(to items: [LiveItem], known: [String: [CGWindowID]] = [:]) -> [String: CGWindowID] {
        let knownIDs = Set(known.values.flatMap { $0 })
        let items = items.filter { $0.frame.width > 0 && known[$0.key] == nil }.sorted { $0.frame.minX < $1.frame.minX }
        guard !items.isEmpty else { return [:] }
        // The display Accessibility reports on: the most common vertical position.
        let ys = items.map { Int($0.frame.midY.rounded()) }
        let barY = CGFloat(Dictionary(grouping: ys, by: { $0 }).max { $0.value.count < $1.value.count }!.key)
        let wins: [(CGWindowID, CGRect)] = menuBarWindows().compactMap { id in
            guard !knownIDs.contains(id), let f = frame(of: id), f.width < 600, abs(f.midY - barY) < 12 else { return nil } // skip whole-bar windows
            return (id, f)
        }.sorted { $0.1.minX < $1.1.minX }

        // Anchors: exact matches, kept only while both orders increase.
        var anchors: [(Int, Int)] = []
        var lastW = -1
        for (i, it) in items.enumerated() {
            guard let j = wins.indices.filter({ $0 > lastW }).min(by: { abs(wins[$0].1.midX - it.frame.midX) < abs(wins[$1].1.midX - it.frame.midX) }),
                  abs(wins[j].1.midX - it.frame.midX) < 4 else { continue }
            anchors.append((i, j))
            lastW = j
        }
        var out: [String: CGWindowID] = [:]
        for (i, j) in anchors { out[items[i].key] = wins[j].0 }
        let bounds = [(-1, -1)] + anchors + [(items.count, wins.count)]
        for k in 0..<(bounds.count - 1) {
            let (i0, j0) = bounds[k], (i1, j1) = bounds[k + 1]
            guard i1 - i0 == j1 - j0, i1 - i0 > 1 else { continue }
            for d in 1..<(i1 - i0) { out[items[i0 + d].key] = wins[j0 + d].0 }
        }
        // Our own items: their window on the same display.
        for (key, ids) in known {
            out[key] = ids.first { id in frame(of: id).map { abs($0.midY - barY) < 12 } ?? false } ?? ids.first
        }
        return out
    }

    /// Moves `window` so it ends up just left of `anchor`. Returns true once its frame has changed.
    ///
    /// Measured on macOS 26: the mouse-down must be at the item's own position (even when the
    /// item isn't drawn); then a mouse-up on the anchor's left edge inserts it left of the anchor.
    /// (A mouse-down far off screen, as Ice does, always inserts right of the anchor.) The anchor
    /// must be drawn: a drop where nothing is drawn sends the item to the far left.
    @discardableResult
    static func move(_ window: CGWindowID, leftOf anchor: CGWindowID) -> Bool {
        // Items slide for a moment after others leave or arrive; grabbing one while it slides
        // misses it (measured: an item still sliding 18, 7, then 3 points right).
        settle([window, anchor])
        guard let start = frame(of: window), let dest = frame(of: anchor) else { return false }
        let grab = CGPoint(x: start.midX, y: start.midY)
        let drop = CGPoint(x: dest.minX + 2, y: dest.midY)

        guard let source = CGEventSource(stateID: .combinedSessionState) else { return false }
        let allow: CGEventFilterMask = [.permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents]
        source.setLocalEventsFilterDuringSuppressionState(allow, state: .eventSuppressionStateRemoteMouseDrag)
        source.setLocalEventsFilterDuringSuppressionState(allow, state: .eventSuppressionStateSuppressionInterval)
        source.localEventsSuppressionInterval = 0

        // The events move the real cursor; macOS ignores them otherwise (events sent straight to
        // Control Center do nothing). So hide the cursor, ignore the user's mouse while the drag
        // is under way, and put the cursor back where it was.
        let cursor = CGEvent(source: nil)?.location
        hideCursor()
        defer {
            if let cursor { CGWarpMouseCursorPosition(cursor) }
            CGAssociateMouseAndMouseCursorPosition(1)
            CGDisplayShowCursor(CGMainDisplayID())
        }

        guard let down = event(.leftMouseDown, at: grab, window: window, command: true),
              let up = event(.leftMouseUp, at: drop, window: anchor, command: false)
        else { return false }
        down.post(tap: .cgSessionEventTap)
        usleep(60_000)
        up.post(tap: .cgSessionEventTap)

        // Wait for the window server to show the new position.
        for _ in 0..<40 {
            usleep(15_000)
            if let now = frame(of: window), now != start { settle([window]); return true }
        }
        return false
    }

    // MARK: Keeping the user's mouse out of the way

    /// Tags PeaceMenu's own events, so the tap lets them through.
    private static let marker: Int64 = 0x5045_4143_45 // "PEACE"
    private static var tap: CFMachPort?
    private static var exclusiveDepth = 0
    private static let exclusiveLock = NSLock()
    private static var exclusiveSince = Date.distantPast
    private static var isExclusive: Bool { exclusiveLock.withLock { exclusiveDepth > 0 } }
    /// Never hold the user's clicks off for more than 10 seconds, whatever happens.
    private static var holdsClicks: Bool {
        exclusiveLock.withLock { exclusiveDepth > 0 && Date().timeIntervalSince(exclusiveSince) < 10 }
    }

    /// Runs a series of moves as one: the user's clicks and drags are dropped throughout, so they
    /// can't tangle with the drags PeaceMenu makes. The cursor is hidden only during each move
    /// (keeping it hidden for the whole series made it look lost).
    static func exclusive<T>(_ work: () -> T) -> T {
        let first = exclusiveLock.withLock {
            exclusiveDepth += 1
            if exclusiveDepth == 1 { exclusiveSince = Date() }
            return exclusiveDepth == 1
        }
        if first {
            installTap()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            DispatchQueue.main.async { Busy.start() }
        }
        defer {
            let last = exclusiveLock.withLock { exclusiveDepth -= 1; return exclusiveDepth == 0 }
            if last {
                if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
                DispatchQueue.main.async { Busy.stop() }
            }
        }
        return work()
    }

    /// The "busy but clickable" cursor (an arrow with a spinning wheel), shown while PeaceMenu
    /// holds the user's clicks off, so it's clear the computer is busy, not stuck.
    private enum Busy {
        static var timer: Timer?
        static var frame = 0
        static let cursors: [NSCursor] = {
            let dir = "/System/Library/Frameworks/ApplicationServices.framework/Versions/A/Frameworks/HIServices.framework/Versions/A/Resources/cursors/busybutclickable/"
            guard let pdf = NSImage(contentsOfFile: dir + "cursor.pdf") else { return [] }
            let info = NSDictionary(contentsOfFile: dir + "info.plist")
            let count = (info?["frames"] as? Int) ?? 15
            let hot = NSPoint(x: (info?["hotx"] as? Double) ?? 5, y: (info?["hoty"] as? Double) ?? 5)
            let w = pdf.size.width, h = pdf.size.height / CGFloat(count)
            return (0..<count).map { i in
                let img = NSImage(size: NSSize(width: w, height: h), flipped: false) { _ in
                    pdf.draw(in: NSRect(x: 0, y: 0, width: w, height: h),
                             from: NSRect(x: 0, y: pdf.size.height - CGFloat(i + 1) * h, width: w, height: h),
                             operation: .sourceOver, fraction: 1)
                    return true
                }
                return NSCursor(image: img, hotSpot: hot)
            }
        }()

        static func start() {
            _ = allowCursorInBackground
            guard timer == nil, !cursors.isEmpty else { return }
            timer = Timer.scheduledTimer(withTimeInterval: 0.033, repeats: true) { _ in
                cursors[frame % cursors.count].set()
                frame += 1
            }
            RunLoop.main.add(timer!, forMode: .common)
        }

        static func stop() {
            timer?.invalidate()
            timer = nil
            NSCursor.arrow.set()
        }
    }

    /// A session event tap on the main run loop, off until `exclusive` turns it on.
    private static func installTap() {
        guard tap == nil else { return }
        let types: [CGEventType] = [.leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .rightMouseUp,
                                    .rightMouseDragged, .otherMouseDown, .otherMouseUp, .otherMouseDragged, .scrollWheel]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = Mover.tap, Mover.isExclusive { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            guard Mover.holdsClicks, event.getIntegerValueField(.eventSourceUserData) != Mover.marker else {
                return Unmanaged.passUnretained(event)
            }
            return nil // the user's click, while PeaceMenu is moving items
        }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: callback, userInfo: nil) else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        DispatchQueue.main.async { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = port
    }

    /// Waits until the windows have stayed put for 45 ms (at most 0.6 s).
    private static func settle(_ windows: [CGWindowID]) {
        var last = windows.map(frame(of:))
        var still = 0
        for _ in 0..<40 {
            usleep(15_000)
            let now = windows.map(frame(of:))
            if now == last { still += 1; if still >= 3 { return } } else { still = 0; last = now }
        }
    }

    /// Hides the cursor on every display and detaches it from the mouse. A background app may
    /// only hide the cursor once its connection has the "SetsCursorInBackground" property.
    private static let allowCursorInBackground: Void = {
        let cid = CGSMainConnectionID()
        _ = CGSSetConnectionProperty(cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    }()
    private static func hideCursor() {
        _ = allowCursorInBackground
        CGDisplayHideCursor(CGMainDisplayID())
        CGAssociateMouseAndMouseCursorPosition(0)
    }

    private static func event(_ type: CGEventType, at p: CGPoint, window: CGWindowID, command: Bool) -> CGEvent? {
        guard let e = CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState), mouseType: type,
                              mouseCursorPosition: p, mouseButton: .left) else { return nil }
        e.flags = command ? .maskCommand : []
        e.setIntegerValueField(.eventSourceUserData, value: marker)
        e.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window))
        e.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window))
        e.setIntegerValueField(windowIDField, value: Int64(window))
        return e
    }
}

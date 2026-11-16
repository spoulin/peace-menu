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
        e.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window))
        e.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window))
        e.setIntegerValueField(windowIDField, value: Int64(window))
        return e
    }
}

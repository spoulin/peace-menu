import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A key with its modifiers, as typed in the shortcut recorder.
struct Shortcut: Codable, Equatable {
    var keyCode: UInt16
    /// NSEvent.ModifierFlags raw value (Command, Option, Control, Shift only).
    var modifiers: UInt
    /// The key's character without modifiers, for display.
    var key: String

    static let relevant: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers).intersection(Self.relevant) }

    /// Modifiers in the form RegisterEventHotKey expects.
    var carbonModifiers: UInt32 {
        var m = 0
        if flags.contains(.command) { m |= cmdKey }
        if flags.contains(.option) { m |= optionKey }
        if flags.contains(.control) { m |= controlKey }
        if flags.contains(.shift) { m |= shiftKey }
        return UInt32(m)
    }

    /// For example "⌥Space", in the order macOS menus use.
    var display: String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        switch Int(keyCode) {
        case kVK_Space: return s + "Space"
        case kVK_Tab: return s + "⇥"
        case kVK_Return: return s + "↩"
        case kVK_Escape: return s + "⎋"
        case kVK_ANSI_Grave: return s + "`"
        default: return s + key.uppercased()
        }
    }
}

/// One system-wide shortcut. Carbon hot keys work while PeaceMenu is in the background, with
/// no permission.
final class HotKey {
    static let shared = HotKey()

    var onPress: (() -> Void)?
    private var ref: EventHotKeyRef?
    private var handlerInstalled = false
    private(set) var current: Shortcut?

    /// Registers `shortcut` in place of the previous one; nil removes it. Returns false when
    /// macOS refused it (usually because another app owns it).
    @discardableResult
    func set(_ shortcut: Shortcut?) -> Bool {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        current = shortcut
        guard let shortcut else { return true }
        installHandler()
        let id = EventHotKeyID(signature: OSType(0x5045_4143), id: 1) // "PEAC"
        let status = RegisterEventHotKey(UInt32(shortcut.keyCode), shortcut.carbonModifiers, id, GetEventDispatcherTarget(), 0, &ref)
        if status != noErr { log("shortcut \(shortcut.display) refused: \(status)") }
        return status == noErr
    }

    private func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, _, _ in
            DispatchQueue.main.async { HotKey.shared.onPress?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

/// Click, then type the new shortcut. Escape cancels; Delete removes the shortcut.
struct ShortcutRecorder: View {
    @Binding var shortcut: Shortcut?
    @State private var monitor: Any?
    @State private var recording = false

    var body: some View {
        Button { recording ? stop() : start() } label: {
            Text(recording ? "Type the shortcut…" : (shortcut?.display ?? "None"))
                .monospacedDigit()
                .frame(minWidth: 110)
        }
        .help("Click, then type the new shortcut. Escape cancels, Delete removes it.")
        .onDisappear { stop() }
    }

    private func start() {
        stop()
        recording = true
        // The current shortcut would fire instead of being typed.
        HotKey.shared.set(nil)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(Shortcut.relevant)
            switch Int(event.keyCode) {
            case kVK_Escape where flags.isEmpty:
                stop()
            case kVK_Delete where flags.isEmpty, kVK_ForwardDelete where flags.isEmpty:
                shortcut = nil
                stop()
            default:
                // Command, Option or Control, or it would get in the way of typing.
                guard !flags.subtracting(.shift).isEmpty else { NSSound.beep(); return nil }
                let key = (event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers ?? "").lowercased()
                shortcut = Shortcut(keyCode: event.keyCode, modifiers: flags.rawValue, key: key)
                stop()
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording {
            recording = false
            HotKey.shared.set(shortcut)
        }
    }
}

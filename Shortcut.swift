// Shortcut: a key plus modifiers in Carbon codes (what RegisterEventHotKey takes), its menu-style
// label, and the recorder button that sets one by pressing the keys. Shortcuts with Fn go to the
// event tap (KeyTap.swift) instead: Carbon hot keys have no Fn modifier.
import Carbon.HIToolbox
import SwiftUI

struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32  // Carbon modifier mask, plus fnMask for Fn

    /// Carbon's kEventKeyModifierFnMask value. Never passed to RegisterEventHotKey.
    static let fnMask = UInt32(1 << 17)
    static let talkDefault = Shortcut(keyCode: UInt32(kVK_Function), modifiers: fnMask)
    static let handsFreeDefault = Shortcut(keyCode: UInt32(kVK_Space), modifiers: fnMask)

    var usesFn: Bool { modifiers & Shortcut.fnMask != 0 }
    var isFnOnly: Bool { keyCode == UInt32(kVK_Function) }
    var needsTap: Bool { usesFn }  // Carbon cannot see Fn: the event tap handles these

    /// The pressed keys as a shortcut. A flagsChanged of the Fn key itself is Fn alone. A keyDown
    /// needs ⌃, ⌥ or Fn: `fnHeld` comes from the recorder, which saw the Fn key go down (NSEvent
    /// also flags arrows and F-keys as `.function`, so that flag cannot tell). ⇧ or ⌘ alone does
    /// not count: a registered hot key is swallowed system-wide, so ⇧D would eat every capital D,
    /// and a ⌘W or ⌘Q pressed by accident while the recorder listens would stop working everywhere.
    static func from(_ event: NSEvent, fnHeld: Bool) -> Shortcut? {
        if event.type == .flagsChanged {
            return event.keyCode == UInt16(kVK_Function) ? talkDefault : nil
        }
        let pairs: [(NSEvent.ModifierFlags, Int)] = [
            (.control, controlKey), (.option, optionKey), (.shift, shiftKey), (.command, cmdKey)]
        let carbon = pairs.filter { event.modifierFlags.contains($0.0) }.reduce(0) { $0 | $1.1 }
        let mods = UInt32(carbon) | (fnHeld ? fnMask : 0)
        guard mods & (UInt32(controlKey | optionKey) | fnMask) != 0 else { return nil }
        return Shortcut(keyCode: UInt32(event.keyCode), modifiers: mods)
    }

    /// Menu-style label, e.g. "⌃⌥D", "Fn" or "Fn Space".
    var display: String {
        if isFnOnly { return "Fn" }
        let marks = [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
        let mods = marks.filter { modifiers & UInt32($0.0) != 0 }.map { $0.1 }.joined()
        let key = Shortcut.names[Int(keyCode)] ?? Shortcut.typed(keyCode) ?? "key \(keyCode)"
        return (usesFn ? "Fn " : "") + mods + key
    }

    static let names: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Escape: "⎋", kVK_Tab: "⇥", kVK_Delete: "⌫",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12"]

    /// What the current keyboard layout types on this key, uppercased ("D"; "Z" for kVK_ANSI_Y
    /// on a German layout). Nil when the layout has no printable character for it.
    static func typed(_ keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        // The layout bytes belong to `source`: keep it alive until UCKeyTranslate is done.
        return withExtendedLifetime(source) { () -> String? in
            let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
            guard let bytes = CFDataGetBytePtr(data) else { return nil }
            let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
            var deadKeys: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                                        UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysMask),
                                        &deadKeys, chars.count, &length, &chars)
            let junk = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
            let text = String(utf16CodeUnits: chars, count: length).trimmingCharacters(in: junk)
            return status == noErr && !text.isEmpty ? text.uppercased() : nil
        }
    }
}

/// A button showing the shortcut. Click it and press the new keys; Esc or a click elsewhere
/// cancels. Fn pressed and released alone records "Fn"; a key pressed while Fn is down records
/// Fn plus that key. `onRecording` tells the app to pause its hot keys and Fn tap meanwhile: a
/// registered hot key never reaches the window as a key press, so it could not be recorded (or
/// rejected) otherwise.
struct ShortcutRecorder: View {
    @Binding var shortcut: Shortcut
    let conflictsWith: Shortcut?
    var onRecording: (Bool) -> Void = { _ in }
    @State private var monitor: Any?
    @State private var problem = ""
    @State private var fnHeld = false  // the Fn key (keyCode 63) is down
    @State private var fnWithKey = false  // a key was pressed during this Fn press

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Button(action: start) {
                Text(monitor == nil ? shortcut.display : "Press keys…").frame(minWidth: 100)
            }
            if !problem.isEmpty { Text(problem).font(.caption).foregroundColor(.red) }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .onDisappear(perform: stop)
        // Closing the window or switching apps resigns key: stop listening and resume hot keys.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) {
            _ in stop()
        }
    }

    func start() {
        guard monitor == nil else { return }
        onRecording(true)
        fnHeld = false
        let events: NSEvent.EventTypeMask = [.keyDown, .flagsChanged, .leftMouseDown]
        monitor = NSEvent.addLocalMonitorForEvents(matching: events) { event in
            switch event.type {
            case .leftMouseDown:
                stop()
                return event
            case .flagsChanged:
                fnChanged(event)
                return event  // modifier changes always pass through
            default:
                fnWithKey = fnHeld
                record(event)
                return nil  // the keys belong to the recorder, not to whatever control has focus
            }
        }
    }

    /// Fn up with no key pressed since it went down records Fn alone.
    func fnChanged(_ event: NSEvent) {
        guard event.keyCode == UInt16(kVK_Function) else { return }
        let down = event.modifierFlags.contains(.function)
        let alone = fnHeld && !down && !fnWithKey
        fnHeld = down
        fnWithKey = false
        if alone { record(event) }
    }

    func record(_ event: NSEvent) {
        let new = Shortcut.from(event, fnHeld: fnHeld)
        if new == nil, event.keyCode == UInt16(kVK_Escape) { return stop() }
        guard let new = new else {
            problem = "Add ⌃, ⌥ or Fn"
            return
        }
        guard new != conflictsWith else {
            problem = "Already used by the other shortcut"
            return
        }
        shortcut = new  // hot keys are still paused, so this registers nothing yet
        stop()  // resumes hot keys: the new shortcut is registered once, here
    }

    func stop() {
        guard let m = monitor else { return }
        NSEvent.removeMonitor(m)
        monitor = nil
        problem = ""
        onRecording(false)
    }
}

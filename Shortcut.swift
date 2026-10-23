// Shortcut: a key plus modifiers in Carbon codes (what RegisterEventHotKey takes), its menu-style
// label, and the recorder button that sets one by pressing the keys.
import Carbon.HIToolbox
import SwiftUI

struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32  // Carbon modifier mask

    static let talkDefault = Shortcut(keyCode: UInt32(kVK_ANSI_D),
                                      modifiers: UInt32(controlKey | optionKey))
    static let handsFreeDefault = Shortcut(keyCode: UInt32(kVK_Space),
                                           modifiers: UInt32(controlKey | optionKey))

    /// The pressed key as a shortcut; nil when none of ⌃⌥⇧⌘ is held.
    static func from(_ event: NSEvent) -> Shortcut? {
        let pairs: [(NSEvent.ModifierFlags, Int)] = [
            (.control, controlKey), (.option, optionKey), (.shift, shiftKey), (.command, cmdKey)]
        let mods = pairs.filter { event.modifierFlags.contains($0.0) }.reduce(0) { $0 | $1.1 }
        return mods == 0 ? nil : Shortcut(keyCode: UInt32(event.keyCode), modifiers: UInt32(mods))
    }

    /// Menu-style label, e.g. "⌃⌥D" or "⌃⌥Space".
    var display: String {
        let marks = [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
        let mods = marks.filter { modifiers & UInt32($0.0) != 0 }.map { $0.1 }.joined()
        let key = Shortcut.names[Int(keyCode)] ?? Shortcut.typed(keyCode) ?? "key \(keyCode)"
        return mods + key
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
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData),
              let bytes = CFDataGetBytePtr(Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue())
        else { return nil }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        var deadKeys: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                                    UInt32(LMGetKbdType()),
                                    OptionBits(kUCKeyTranslateNoDeadKeysMask),
                                    &deadKeys, chars.count, &length, &chars)
        let text = String(utf16CodeUnits: chars, count: length)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.controlCharacters))
        return status == noErr && !text.isEmpty ? text.uppercased() : nil
    }
}

/// A button showing the shortcut. Click it and press the new keys; Esc or a click elsewhere
/// cancels. `onRecording` tells the app to pause its hot keys meanwhile: a registered hot key
/// never reaches the window as a key press, so it could not be recorded (or rejected) otherwise.
struct ShortcutRecorder: View {
    @Binding var shortcut: Shortcut
    let conflictsWith: Shortcut?
    var onRecording: (Bool) -> Void = { _ in }
    @State private var monitor: Any?
    @State private var problem = ""

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
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { event in
            if event.type == .leftMouseDown {
                stop()
                return event
            }
            record(event)
            return nil  // the keys belong to the recorder, not to whatever control has focus
        }
    }

    func record(_ event: NSEvent) {
        let new = Shortcut.from(event)
        if new == nil, event.keyCode == UInt16(kVK_Escape) { return stop() }
        guard let new = new else {
            problem = "Add ⌃, ⌥, ⇧ or ⌘"
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

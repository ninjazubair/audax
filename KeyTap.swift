// KeyTap: the shortcuts that involve Fn, which Carbon hot keys cannot see. A session event tap
// reports the Fn key alone from its flagsChanged events (keyCode 63) and Fn+key from keyDown/keyUp,
// swallowing a matched key so it is not typed. Creating the tap needs Accessibility, which AUDAX
// already needs for pasting; without it `init` returns nil.
import Carbon.HIToolbox
import Cocoa

final class KeyTap {
    /// (shortcut id, pressed), on the main queue: 1 = talk, 2 = hands-free, as for Carbon.
    var onKey: ((UInt32, Bool) -> Void)?
    /// A key pressed with Fn down that is no shortcut (Fn+Delete, Fn+←…), on the main queue.
    var onFnChord: (() -> Void)?
    private var port: CFMachPort?
    private var shortcuts: [(id: UInt32, shortcut: Shortcut)] = []
    private var fnDown = false
    private var held: [UInt32: UInt32] = [:]  // keyCode → id of a matched Fn+key still down

    init?() {
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged]
        let mask = types.reduce(CGEventMask(0)) { $0 | CGEventMask(1) << $1.rawValue }
        // A C function pointer cannot capture: `self` travels in userInfo.
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: { _, type, event, info in
                guard let info = info else { return Unmanaged.passUnretained(event) }
                let tap = Unmanaged<KeyTap>.fromOpaque(info).takeUnretainedValue()
                return tap.handle(type, event) ? nil : Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return nil }
        self.port = port
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
    }

    var isActive: Bool { port.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    /// The Fn shortcuts to match; [] matches nothing (while a Settings recorder listens).
    func update(_ shortcuts: [(id: UInt32, shortcut: Shortcut)]) {
        self.shortcuts = shortcuts
    }

    /// True for a matched Fn+key, which then never reaches the app in front. Runs inside the
    /// tap, so it only decides: the app reacts on the next main-queue turn. A slow callback
    /// would hold up every key press on the Mac, and a modal alert would hold it for good.
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let port = port { CGEvent.tapEnable(tap: port, enable: true) }
            return false
        case .flagsChanged:
            fnChanged(event)
            return false  // modifier changes always pass through
        case .keyDown, .keyUp:
            return key(event, down: type == .keyDown)
        default:
            return false
        }
    }

    /// The Fn key going down or up: the Fn-only shortcut, if there is one.
    private func fnChanged(_ event: CGEvent) {
        guard event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_Function) else {
            return
        }
        let down = event.flags.contains(.maskSecondaryFn)
        guard down != fnDown else { return }
        fnDown = down
        if let id = shortcuts.first(where: { $0.shortcut.isFnOnly })?.id { report(id, down) }
    }

    /// Fn+key. The release is matched by key alone, so letting go of Fn first still ends a hold.
    /// Auto-repeats are swallowed without a report. An Fn+key that is no shortcut passes through
    /// and is reported as a chord (its repeats are not).
    private func key(_ event: CGEvent, down: Bool) -> Bool {
        let code = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
        if !down {
            guard let id = held.removeValue(forKey: code) else { return false }
            report(id, false)
            return true
        }
        // fnDown as well as the flag: macOS flags arrows and F-keys as Fn even without it.
        guard fnDown, event.flags.contains(.maskSecondaryFn) else { return false }
        let mods = KeyTap.carbon(event.flags) | Shortcut.fnMask
        let pressed = Shortcut(keyCode: code, modifiers: mods)
        let repeated = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        guard let id = shortcuts.first(where: { $0.shortcut == pressed })?.id else {
            if !repeated { DispatchQueue.main.async { [weak self] in self?.onFnChord?() } }
            return false  // keeps its macOS meaning (forward delete, Home, F-key…)
        }
        if !repeated {
            held[code] = id
            report(id, true)
        }
        return true
    }

    private func report(_ id: UInt32, _ pressed: Bool) {
        DispatchQueue.main.async { [weak self] in self?.onKey?(id, pressed) }
    }

    /// ⌃⌥⇧⌘ as a Carbon mask, to compare with a recorded Shortcut.
    static func carbon(_ flags: CGEventFlags) -> UInt32 {
        let pairs: [(CGEventFlags, Int)] = [(.maskControl, controlKey), (.maskAlternate, optionKey),
                                            (.maskShift, shiftKey), (.maskCommand, cmdKey)]
        return UInt32(pairs.filter { flags.contains($0.0) }.reduce(0) { $0 | $1.1 })
    }
}

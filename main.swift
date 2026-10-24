// AUDAX entry point.
import Cocoa

let app = NSApplication.shared
// Before App() makes its first window (the pill) and its menus: no Start Dictation or Emoji &
// Symbols in Edit (registration domain, never written to disk), no window tabs.
UserDefaults.standard.register(defaults: ["NSDisabledDictationMenuItem": true,
                                          "NSDisabledCharacterPaletteMenuItem": true])
NSWindow.allowsAutomaticWindowTabbing = false
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.regular)  // Dock icon, ⌘-Tab and a menu bar; the menu-bar mic stays
app.run()

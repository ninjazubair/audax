// AUDAX entry point.
import Cocoa

// Before NSApplication and App() make the first window (the pill) and the menus (registration
// domain, never written to disk): no Start Dictation or Emoji & Symbols in Edit, and no App Nap.
// Napped (priority 4 instead of 46), a busy CPU kept SIGTERM, SIGUSR1 and the 5 s timer waiting
// 15 s and more (stress run, 2026-10-25). NSAppSleepDisabled is a defaults key: as an Info.plist
// key it changed nothing, nor did LSAppNapIsDisabled there (measured, launched directly).
UserDefaults.standard.register(defaults: ["NSDisabledDictationMenuItem": true,
                                          "NSDisabledCharacterPaletteMenuItem": true,
                                          "NSAppSleepDisabled": true])
let app = NSApplication.shared
NSWindow.allowsAutomaticWindowTabbing = false
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.regular)  // Dock icon, ⌘-Tab and a menu bar; the menu-bar mic stays
app.run()

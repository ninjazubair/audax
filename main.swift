// AUDAX entry point.
import Cocoa

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.regular)  // Dock icon, ⌘-Tab and a menu bar; the menu-bar mic stays
app.run()

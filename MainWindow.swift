// AUDAX's one window: a sidebar (Home, History, the settings panes, About) and a toolbar with
// the dictation state and a Start / Stop button. Opened from the Dock, Launchpad, Finder and the
// menu-bar icon; ⌘, opens it on Dictation. Closing it leaves AUDAX running.
import SwiftUI

enum Pane: String, Identifiable {
    case home, history, dictation, aiProvider, words, about
    var id: Self { self }

    var title: String {
        switch self {
        case .home: return "Home"
        case .history: return "History"
        case .dictation: return "Dictation"
        case .aiProvider: return "AI Provider"
        case .words: return "Words"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .home: return "house"
        case .history: return "clock.arrow.circlepath"
        case .dictation: return "keyboard"
        case .aiProvider: return "sparkles"
        case .words: return "character.book.closed"
        case .about: return "info.circle"
        }
    }
}

struct RootView: View {
    @ObservedObject var model: Model
    @ObservedObject var settings: Settings
    let actions: Actions

    var body: some View {
        // The sidebar always shows: it is the window's only navigation.
        NavigationSplitView(columnVisibility: .constant(.all)) {
            sidebar
                .toolbar(removing: .sidebarToggle)
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        StatusCapsule(model: model)
                        StartStopButton(model: model, toggle: actions.toggle)
                    }
                }
        }
    }

    /// Never empty: a click on blank sidebar space keeps the current pane.
    var selection: Binding<Pane?> {
        Binding(get: { model.pane }, set: { if let pane = $0 { model.pane = pane } })
    }

    var sidebar: some View {
        List(selection: selection) {
            Section("Dictate") {
                row(.home)
                row(.history)
            }
            Section("Settings") {
                row(.dictation)
                row(.aiProvider)
                row(.words)
            }
            Section { row(.about) }
        }
    }

    func row(_ pane: Pane) -> some View {
        Label(pane.title, systemImage: pane.symbol).tag(pane)
    }

    @ViewBuilder var detail: some View {
        switch model.pane {
        case .home: HomeView(model: model, settings: settings, actions: actions)
        case .history: HistoryView(model: model, actions: actions)
        case .dictation: DictationSettingsView(model: model, settings: settings, actions: actions)
        case .aiProvider: AIProviderView(settings: settings, model: model, actions: actions)
        case .words: WordsView(settings: settings)
        case .about: AboutView(actions: actions)
        }
    }
}

/// Grey "Ready", red "Listening 0:07", orange "Transcribing…".
struct StatusCapsule: View {
    @ObservedObject var model: Model

    var body: some View {
        if #available(macOS 26, *) {
            label.padding(.horizontal, 6)  // the toolbar's glass is the capsule
        } else {
            label
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(tint.opacity(0.14), in: Capsule())
        }
    }

    var label: some View {
        HStack(spacing: 6) {
            Circle().fill(tint).frame(width: 7, height: 7)
            Text(text).monospacedDigit()
        }
        .font(.callout.weight(.medium))
        .foregroundStyle(model.phase == .idle ? Color.secondary : tint)
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    var tint: Color {
        switch model.phase {
        case .idle: return .gray
        case .recording: return .red
        case .transcribing: return .orange
        }
    }

    var text: String {
        switch model.phase {
        case .idle: return "Ready"
        case .recording: return "Listening \(clockText(model.seconds))"
        case .transcribing: return "Transcribing…"
        }
    }
}

/// App.toggle(): starts hands-free when idle, finishes any recording.
struct StartStopButton: View {
    @ObservedObject var model: Model
    let toggle: () -> Void

    var body: some View {
        let recording = model.phase == .recording
        Button(action: toggle) {
            Label(recording ? "Stop" : "Start dictation",
                  systemImage: recording ? "stop.fill" : "mic.fill")
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.borderedProminent)
        .tint(recording ? .red : .accentColor)
        .disabled(model.phase == .transcribing)
    }
}

final class MainWindow {
    let window: NSWindow

    init(model: Model, settings: Settings, actions: Actions) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 600),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable,
                                      .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "AUDAX"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 760, height: 520)
        window.toolbarStyle = .unified
        let host = NSHostingView(rootView: RootView(model: model, settings: settings,
                                                    actions: actions))
        host.sizingOptions = [.minSize]  // switching panes never resizes the window
        host.sceneBridgingOptions = [.toolbars]  // SwiftUI's toolbar becomes the window's
        window.contentView = host
        window.center()
        window.setFrameAutosaveName("AUDAXMain")  // restores the last frame, if there is one
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        bringToFront()
    }
}

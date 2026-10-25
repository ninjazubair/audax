// The recording pill: a floating capsule at the bottom centre of the main screen, on every
// Space. Recording: pulsing red dot, live waveform, mode and elapsed time. Then a spinner while
// transcribing, then the result for a moment. It never takes focus or the mouse, and stays up
// while AUDAX is hidden.
import Cocoa
import SwiftUI

final class HUDState: ObservableObject {
    enum Kind { case recording, transcribing, result }
    @Published var kind = Kind.recording
    @Published var handsFree = false
    @Published var levels = [CGFloat](repeating: 0, count: 24)
    @Published var elapsed = 0.0  // seconds since the recording pill appeared
    @Published var text = ""  // the result
    @Published var symbol = ""
}

struct PillView: View {
    @ObservedObject var state: HUDState

    var body: some View {
        content
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder var content: some View {
        switch state.kind {
        case .recording: recording
        case .transcribing:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Transcribing…")
            }
        case .result:
            HStack(spacing: 8) {
                Image(systemName: state.symbol).foregroundStyle(tint)
                Text(state.text).lineLimit(1)
            }
        }
    }

    var recording: some View {
        HStack(spacing: 8) {
            Circle().fill(Color.red)
                .frame(width: 10, height: 10)
                .opacity(0.45 + 0.55 * (0.5 + 0.5 * cos(state.elapsed * 2 * .pi)))
            Waveform(levels: state.levels)
            Spacer(minLength: 0)
            Text(state.handsFree ? "Hands-free" : "Hold")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .fixedSize()
            Text(clockText(Int(state.elapsed))).monospacedDigit().fixedSize()
        }
    }

    var tint: Color {
        if state.symbol.hasPrefix("checkmark") { return .green }
        if state.symbol.hasPrefix("exclamationmark") { return .orange }
        return .secondary
    }
}

/// 24 bars from the voice meter; they move only when a voice is heard.
struct Waveform: View {
    let levels: [CGFloat]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(levels.indices, id: \.self) { i in
                Capsule()
                    .fill(levels[i] > 0.02 ? Color.primary : Color.primary.opacity(0.25))
                    .frame(width: 2, height: 3 + levels[i] * 21)
            }
        }
        .frame(height: 26)
        .animation(.linear(duration: 0.05), value: levels)
    }
}

final class HUD {
    static let height: CGFloat = 46
    static let minWidth: CGFloat = 260
    let state = HUDState()
    let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: minWidth, height: height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
                        defer: true)
    var hideWork: DispatchWorkItem?
    var started = Date()
    var visible = false

    init() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true  // never takes focus from the app being typed into
        panel.hidesOnDeactivate = false  // NSPanel's default hides it when AUDAX is not in front
        panel.canHide = false  // ⌘H on AUDAX leaves the pill up
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isExcludedFromWindowsMenu = true  // the Window menu lists AUDAX's real windows only
        // Always the dark HUD look, as macOS's own HUDs: readable on light and dark wallpapers.
        panel.appearance = NSAppearance(named: .darkAqua)
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = HUD.capsule(height: HUD.height)
        let host = NSHostingView(rootView: PillView(state: state))
        host.autoresizingMask = [.width, .height]
        effect.addSubview(host)
        panel.contentView = effect
    }

    /// Stretchable capsule mask: the ends keep their radius at any width.
    static func capsule(height: CGFloat) -> NSImage {
        let r = height / 2
        let image = NSImage(size: NSSize(width: height + 1, height: height), flipped: false) {
            NSBezierPath(roundedRect: $0, xRadius: r, yRadius: r).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        image.resizingMode = .stretch
        return image
    }

    /// A new recording starts the clock; switching hold → hands-free keeps it.
    func showRecording(mode: RecordMode) {
        if !visible || state.kind != .recording {
            started = Date()
            state.elapsed = 0
            state.levels = state.levels.map { _ in 0 }
        }
        state.handsFree = mode == .toggle
        state.kind = .recording
        present(width: HUD.minWidth)
    }

    func meter(_ level: CGFloat) {
        state.levels.removeFirst()
        state.levels.append(level)
        state.elapsed = Date().timeIntervalSince(started)
    }

    func showTranscribing() {
        state.kind = .transcribing
        present(width: HUD.minWidth)
    }

    /// The result, e.g. "Pasted" with checkmark.circle.fill, then the pill goes.
    func flash(_ text: String, symbol: String, seconds: Double = 1.2) {
        state.text = text
        state.symbol = symbol
        state.kind = .result
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let textWidth = (text as NSString).size(withAttributes: [.font: font]).width
        present(width: max(HUD.minWidth, ceil(textWidth) + 64))
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// Fades out with a slight shrink; a show meanwhile keeps it up.
    func hide() {
        hideWork?.cancel()
        hideWork = nil
        guard visible else { return }
        visible = false
        let frame = panel.frame
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            panel.animator().setFrame(HUD.shrunk(frame), display: true)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self = self, !self.visible else { return }
            self.panel.orderOut(nil)
        })
    }

    /// Bottom centre of the main screen. Fades in with a slight grow when it was hidden;
    /// otherwise only resizes.
    private func present(width: CGFloat) {
        hideWork?.cancel()
        hideWork = nil
        guard let screen = NSScreen.main?.visibleFrame else { return }
        let frame = NSRect(x: (screen.midX - width / 2).rounded(), y: screen.minY + 48,
                           width: width, height: HUD.height)
        if visible {
            panel.setFrame(frame, display: true)
            return
        }
        visible = true
        panel.setFrame(HUD.shrunk(frame), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().setFrame(frame, display: true)
            panel.animator().alphaValue = 1
        }
    }

    static func shrunk(_ frame: NSRect) -> NSRect {
        frame.insetBy(dx: frame.width * 0.04, dy: frame.height * 0.04)
    }
}

// About: the icon, the version with its build stamp (both from the bundle, set by build.sh), and
// links to the release notes, the log folder and setup.
import SwiftUI

struct AboutView: View {
    let actions: Actions
    static let releases = URL(string: "https://github.com/zuhussai_adobe/audax/releases")!

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage).resizable()
                .frame(width: 112, height: 112)
                .accessibilityHidden(true)
            VStack(spacing: 4) {
                Text("AUDAX").font(.largeTitle.weight(.bold))
                Text(Self.versionLine).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Text("Local dictation for your Mac: hold a key, speak, and the text appears "
                 + "where you type.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 360)
            links.padding(.top, 8)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var links: some View {
        HStack(spacing: 12) {
            Button { NSWorkspace.shared.open(Self.releases) } label: {
                Label("Release notes", systemImage: "doc.text")
            }
            Button { NSWorkspace.shared.open(URL(fileURLWithPath: stateDir)) } label: {
                Label("Open log folder", systemImage: "folder")
            }
            Button(action: actions.runSetup) {
                Label("Run setup again", systemImage: "arrow.clockwise")
            }
        }
    }

    /// "Version 0.4.0 (20261024-121737)": the bundle's short version, then its build stamp.
    static var versionLine: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info["CFBundleVersion"] as? String ?? ""
        return "Version \(version)" + (build.isEmpty ? "" : " (\(build))")
    }
}

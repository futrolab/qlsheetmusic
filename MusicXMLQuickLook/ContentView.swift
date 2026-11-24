import AppKit
import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "music.note.list")
                    .font(.system(size: 32))
                    .foregroundStyle(.tint)

                VStack(alignment: .leading, spacing: 2) {
                    Text("MusicXML Quick Look")
                        .font(.headline)
                    Text("Finder Spacebar preview for .musicxml, .mxl, and .mscz files")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("1. Enable the extension in System Settings → General → Login Items & Extensions → Quick Look.")
                Text("2. Select any .musicxml, .mxl, or .mscz file in Finder and press Spacebar.")
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Open Extensions Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

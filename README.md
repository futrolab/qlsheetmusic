# MusicXMLQuickLook

macOS Quick Look Preview Extension (`.appex`) for `.musicxml`, `.mxl`, and `.mscz` files.

- **`.musicxml` / `.mxl`**: Unpacked in memory via Apple's `Compression` framework (`META-INF/container.xml`) and rendered offline to SVG using bundled [OpenSheetMusicDisplay](https://github.com/opensheetmusicdisplay/opensheetmusicdisplay) inside `WKWebView`.
- **`.mscz`**: Unpacked in memory to display MuseScore's embedded `Thumbnails/thumbnail.png` scaled to fit the preview window (with a fallback notice if saved without a thumbnail).

## Quick Start (Command Line Tools Only)

Works with Apple Command Line Tools (`swiftc`, `codesign`, `plutil`) — no full Xcode required:

```bash
git clone <your-repo-url>
cd MacOS_Quick_Look_Music_Formats
./Scripts/build-without-xcode.sh
```

On first run, `build-without-xcode.sh` automatically fetches `opensheetmusicdisplay@3.0.0` into `build/MusicXMLQuickLook.app` (override with `BUNDLE_ID_PREFIX=com.yourname` if desired).

### Register & Test

```bash
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f build/MusicXMLQuickLook.app
pluginkit -a build/MusicXMLQuickLook.app/Contents/PlugIns/MusicXMLPreviewExtension.appex
pluginkit -e use -i com.futrolab.MusicXMLQuickLook.PreviewExtension
qlmanage -r && qlmanage -r cache

qlmanage -p /path/to/score.musicxml
qlmanage -p /path/to/score.mxl
qlmanage -p /path/to/score.mscz
```

> **macOS Sandbox Note:** Both `.entitlements` files include `com.apple.security.app-sandbox` and `com.apple.security.network.client`. Even for local `file://` HTML, WebKit's child XPC services (`WebContent`, `GPU`, `Networking`) require `com.apple.security.network.client` on macOS 15+.

## Build with XcodeGen + Full Xcode (Optional)

Requires full Xcode (`xcode-select -s /Applications/Xcode.app/Contents/Developer`), `brew install xcodegen`, and a local OSMD bundle in `MusicXMLPreviewExtension/Resources/`:

```bash
curl -fsSL \
  https://cdn.jsdelivr.net/npm/opensheetmusicdisplay@3.0.0/build/opensheetmusicdisplay.min.js \
  -o MusicXMLPreviewExtension/Resources/opensheetmusicdisplay.min.js

xcodegen generate
xcodebuild -project MusicXMLQuickLook.xcodeproj \
  -scheme MusicXMLQuickLook \
  -configuration Release \
  -derivedDataPath build \
  build

cp -R build/Build/Products/Release/MusicXMLQuickLook.app /Applications/
open /Applications/MusicXMLQuickLook.app
pluginkit -a /Applications/MusicXMLQuickLook.app/Contents/PlugIns/MusicXMLPreviewExtension.appex
pluginkit -e use -i com.futrolab.MusicXMLQuickLook.PreviewExtension
qlmanage -r && qlmanage -r cache
```

## Manual Xcode Setup

1. Create a **macOS App** project named `MusicXMLQuickLook` (SwiftUI, Deployment Target 13.0, Bundle ID `com.futrolab.MusicXMLQuickLook`).
2. Add a **Quick Look Preview Extension** target named `MusicXMLPreviewExtension` (Bundle ID `com.futrolab.MusicXMLQuickLook.PreviewExtension`, Deployment Target 13.0).
3. Replace the generated files with `MusicXMLQuickLook/*` and `MusicXMLPreviewExtension/*`.
4. Add `MusicXMLPreviewExtension/Resources/index.html` and `opensheetmusicdisplay.min.js` to **Copy Bundle Resources**, and link `QuickLookUI.framework` + `WebKit.framework`.

## License

MIT — see [LICENSE](LICENSE). Bundled OpenSheetMusicDisplay is licensed under BSD-3-Clause.

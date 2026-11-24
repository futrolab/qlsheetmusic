# MusicXMLQuickLook

macOS Quick Look Preview Extension (`.appex`) for `.musicxml` and `.mxl` files using local OpenSheetMusicDisplay inside `WKWebView`.

## Prerequisites (Rebuilding from Source)

Fetch the local **OpenSheetMusicDisplay** bundle into `MusicXMLPreviewExtension/Resources/` before building (Quick Look extensions render offline):

```bash
curl -fsSL \
  https://cdn.jsdelivr.net/npm/opensheetmusicdisplay@1.8.9/build/opensheetmusicdisplay.min.js \
  -o MusicXMLPreviewExtension/Resources/opensheetmusicdisplay.min.js
```

Or via `npm`:

```bash
npm install --no-save opensheetmusicdisplay
cp node_modules/opensheetmusicdisplay/build/opensheetmusicdisplay.min.js \
   MusicXMLPreviewExtension/Resources/opensheetmusicdisplay.min.js
```

> **Note:** Both `.entitlements` files include `com.apple.security.app-sandbox` and `com.apple.security.network.client`. Even for local `file://` HTML, WebKit's child XPC services (`WebContent`, `GPU`, `Networking`) require `com.apple.security.network.client` on macOS 15+.

## Option A: Build Without Full Xcode (CommandLineTools Only)

Works with only Apple Command Line Tools (`swiftc`, `codesign`, `plutil`) for local use on this Mac:

```bash
./Scripts/build-without-xcode.sh
```

Output bundle: `build/MusicXMLQuickLook.app` (ad-hoc signed, with `MusicXMLPreviewExtension.appex` embedded in `Contents/PlugIns/`).

### Register & Test

```bash
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f build/MusicXMLQuickLook.app
pluginkit -a build/MusicXMLQuickLook.app/Contents/PlugIns/MusicXMLPreviewExtension.appex
pluginkit -e use -i com.futrolab.MusicXMLQuickLook.PreviewExtension
qlmanage -r && qlmanage -r cache

qlmanage -p /path/to/score.musicxml
qlmanage -p /path/to/score.mxl
```

Once built, `opensheetmusicdisplay.min.js` is embedded inside `build/MusicXMLQuickLook.app/Contents/PlugIns/MusicXMLPreviewExtension.appex/Contents/Resources/` — the source copy in `MusicXMLPreviewExtension/Resources/` is only needed when rebuilding.

## Option B: Build with XcodeGen + Full Xcode

Requires full Xcode (`xcode-select -s /Applications/Xcode.app/Contents/Developer`) and `brew install xcodegen`:

```bash
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

## Option C: Manual Xcode Setup

1. Create a **macOS App** project named `MusicXMLQuickLook` (SwiftUI, Deployment Target 13.0, Bundle ID `com.futrolab.MusicXMLQuickLook`).
2. Add a new target: **macOS → Quick Look Preview Extension** named `MusicXMLPreviewExtension` (Bundle ID `com.futrolab.MusicXMLQuickLook.PreviewExtension`, Deployment Target 13.0).
3. Replace the generated files with `MusicXMLQuickLook/*` and `MusicXMLPreviewExtension/*`.
4. Ensure `MusicXMLPreviewExtension/Resources/index.html` and `opensheetmusicdisplay.min.js` are listed in `MusicXMLPreviewExtension → Build Phases → Copy Bundle Resources`.
5. Link `QuickLookUI.framework` and `WebKit.framework` in `MusicXMLPreviewExtension → Frameworks and Libraries`, then build and run the `MusicXMLQuickLook` scheme once.

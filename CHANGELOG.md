# Changelog

All notable changes to **qlsheetmusic** will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-11-25

### Added
- macOS Quick Look Preview Extension (`.appex`) and minimal SwiftUI host app for macOS 13+.
- Offline rendering of `.musicxml` and compressed `.mxl` files using OpenSheetMusicDisplay `3.0.0` inside `WKWebView`.
- Pure-Swift in-memory ZIP extraction (`MXLArchive`) using Apple's `Compression` framework (`META-INF/container.xml` resolution, UTF-8/UTF-16/Windows-1252/ISO-8859-1 XML decoding).
- Quick Look support for MuseScore `.mscz` files (`org.musescore.mscz`) displaying the embedded `Thumbnails/thumbnail.png` scaled to the preview window, with a fallback message when no thumbnail is embedded.
- UTI declarations (`org.recordare.musicxml`, `org.recordare.musicxml.zip`, `org.musescore.mscz`) that do not hijack generic `.xml` files.
- `Scripts/build-without-xcode.sh` for building and ad-hoc signing with Command Line Tools only, alongside `project.yml` for XcodeGen.

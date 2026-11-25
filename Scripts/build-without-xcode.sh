#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build"
APP_NAME="MusicXMLQuickLook"
EXT_NAME="MusicXMLPreviewExtension"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
EXT_BUNDLE="${APP_BUNDLE}/Contents/PlugIns/${EXT_NAME}.appex"
OSMD_SRC="${ROOT_DIR}/MusicXMLPreviewExtension/Resources/opensheetmusicdisplay.min.js"
OSMD_BUNDLED="${EXT_BUNDLE}/Contents/Resources/opensheetmusicdisplay.min.js"
OSMD_CACHE="${BUILD_DIR}/.cached-opensheetmusicdisplay.min.js"
OSMD_VERSION="${OSMD_VERSION:-3.0.0}"
BUNDLE_ID_PREFIX="${BUNDLE_ID_PREFIX:-com.futrolab}"

mkdir -p "${BUILD_DIR}"

if [[ -f "${OSMD_SRC}" ]]; then
  cp "${OSMD_SRC}" "${OSMD_CACHE}"
elif [[ -f "${OSMD_BUNDLED}" ]]; then
  cp "${OSMD_BUNDLED}" "${OSMD_CACHE}"
else
  echo "Fetching opensheetmusicdisplay@${OSMD_VERSION}..."
  curl -fsSL \
    "https://cdn.jsdelivr.net/npm/opensheetmusicdisplay@${OSMD_VERSION}/build/opensheetmusicdisplay.min.js" \
    -o "${OSMD_CACHE}"
fi

ARCH="$(uname -m)"
TARGET="${ARCH}-apple-macosx13.0"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
MODULE_CACHE="${BUILD_DIR}/ModuleCache"

rm -rf "${APP_BUNDLE}"
mkdir -p \
  "${APP_BUNDLE}/Contents/MacOS" \
  "${APP_BUNDLE}/Contents/Resources" \
  "${EXT_BUNDLE}/Contents/MacOS" \
  "${EXT_BUNDLE}/Contents/Resources" \
  "${MODULE_CACHE}"

printf 'APPL????' > "${APP_BUNDLE}/Contents/PkgInfo"

render_plist() {
  local src="$1"
  local dst="$2"
  local exec_name="$3"
  local bundle_id="$4"
  local product_name="$5"
  local module_name="$6"

  python3 - "$src" "$dst" "$exec_name" "$bundle_id" "$product_name" "$module_name" <<'PY'
import sys

src, dst, exec_name, bundle_id, product_name, module_name = sys.argv[1:7]
with open(src, "r", encoding="utf-8") as f:
    text = f.read()

replacements = {
    "$(DEVELOPMENT_LANGUAGE)": "en",
    "$(EXECUTABLE_NAME)": exec_name,
    "$(PRODUCT_BUNDLE_IDENTIFIER)": bundle_id,
    "$(PRODUCT_NAME)": product_name,
    "$(MARKETING_VERSION)": "1.0.0",
    "$(CURRENT_PROJECT_VERSION)": "1",
    "$(MACOSX_DEPLOYMENT_TARGET)": "13.0",
    "$(PRODUCT_MODULE_NAME)": module_name,
}
for k, v in replacements.items():
    text = text.replace(k, v)

with open(dst, "w", encoding="utf-8") as f:
    f.write(text)
PY
  plutil -lint "${dst}" >/dev/null
}

echo "[1/4] Compiling ${EXT_NAME}.appex (${TARGET})..."
swiftc \
  -O \
  -parse-as-library \
  -application-extension \
  -target "${TARGET}" \
  -sdk "${SDK_PATH}" \
  -module-cache-path "${MODULE_CACHE}" \
  -module-name "${EXT_NAME}" \
  -framework AppKit \
  -framework Foundation \
  -framework QuickLookUI \
  -framework WebKit \
  -Xlinker -e -Xlinker _NSExtensionMain \
  "${ROOT_DIR}/MusicXMLPreviewExtension/MXLArchive.swift" \
  "${ROOT_DIR}/MusicXMLPreviewExtension/PreviewViewController.swift" \
  -o "${EXT_BUNDLE}/Contents/MacOS/${EXT_NAME}"

cp "${ROOT_DIR}/MusicXMLPreviewExtension/Resources/index.html" "${EXT_BUNDLE}/Contents/Resources/"
mv "${OSMD_CACHE}" "${EXT_BUNDLE}/Contents/Resources/opensheetmusicdisplay.min.js"

render_plist \
  "${ROOT_DIR}/MusicXMLPreviewExtension/Info.plist" \
  "${EXT_BUNDLE}/Contents/Info.plist" \
  "${EXT_NAME}" \
  "${BUNDLE_ID_PREFIX}.MusicXMLQuickLook.PreviewExtension" \
  "${EXT_NAME}" \
  "${EXT_NAME}"

echo "[2/4] Compiling ${APP_NAME}.app (${TARGET})..."
swiftc \
  -O \
  -parse-as-library \
  -target "${TARGET}" \
  -sdk "${SDK_PATH}" \
  -module-cache-path "${MODULE_CACHE}" \
  -module-name "${APP_NAME}" \
  -framework AppKit \
  -framework SwiftUI \
  "${ROOT_DIR}/MusicXMLQuickLook/MusicXMLQuickLookApp.swift" \
  "${ROOT_DIR}/MusicXMLQuickLook/ContentView.swift" \
  -o "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"

render_plist \
  "${ROOT_DIR}/MusicXMLQuickLook/Info.plist" \
  "${APP_BUNDLE}/Contents/Info.plist" \
  "${APP_NAME}" \
  "${BUNDLE_ID_PREFIX}.MusicXMLQuickLook" \
  "${APP_NAME}" \
  "${APP_NAME}"

echo "[3/4] Ad-hoc signing extension and host app..."
codesign --force --sign - \
  --entitlements "${ROOT_DIR}/MusicXMLPreviewExtension/MusicXMLPreviewExtension.entitlements" \
  "${EXT_BUNDLE}"

codesign --force --sign - \
  --entitlements "${ROOT_DIR}/MusicXMLQuickLook/MusicXMLQuickLook.entitlements" \
  "${APP_BUNDLE}"

echo "[4/4] Verifying code signatures..."
codesign --verify --deep --strict "${APP_BUNDLE}"
echo "Built successfully: ${APP_BUNDLE}"

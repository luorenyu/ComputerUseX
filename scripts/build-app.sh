#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${ROOT_DIR}/dist"
APP_BUNDLE="${DIST_DIR}/ComputerUseX.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

echo "🔨 Building ComputerUseX (Release)..."
cd "${ROOT_DIR}"
swift build -c release

echo "📦 Packaging ${APP_BUNDLE}..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

cp "${ROOT_DIR}/Info.plist" "${CONTENTS_DIR}/Info.plist"
cp "${ROOT_DIR}/.build/release/ComputerUseXApp" "${MACOS_DIR}/ComputerUseXApp"
cp "${ROOT_DIR}/.build/release/cux" "${MACOS_DIR}/cux"
cp "${ROOT_DIR}/.build/release/cux" "${DIST_DIR}/cux"

chmod +x "${MACOS_DIR}/ComputerUseXApp" "${MACOS_DIR}/cux" "${DIST_DIR}/cux" "${ROOT_DIR}/scripts/generate-icon.swift"

echo "🎨 Generating Google Gemini Aurora AppIcon.icns..."
swift "${ROOT_DIR}/scripts/generate-icon.swift" "${RESOURCES_DIR}/AppIcon.icns" "${RESOURCES_DIR}/app-icon.png"
mkdir -p "${ROOT_DIR}/plugins/codex/plugins/computer-use-x/assets"
cp "${RESOURCES_DIR}/app-icon.png" "${ROOT_DIR}/plugins/codex/plugins/computer-use-x/assets/app-icon.png"

# Prefer a deterministic Apple Development certificate (sorted by name) so rebuilds keep macOS TCC permissions;
# otherwise fall back to ad-hoc signature.
DEV_IDENTITY_LINE="$(security find-identity -v -p codesigning 2>/dev/null | grep "Apple Development:" | sort -k3 | head -n 1 || true)"
DEV_HASH="$(echo "${DEV_IDENTITY_LINE}" | awk '{print $2}' || true)"
DEV_NAME="$(echo "${DEV_IDENTITY_LINE}" | awk -F'"' '{print $2}' || true)"

if [[ -n "${DEV_HASH}" ]]; then
    echo "🔏 Signing bundle with stable developer identity: ${DEV_NAME} (${DEV_HASH})"
    codesign --force --sign "${DEV_HASH}" "${MACOS_DIR}/cux"
    codesign --force --sign "${DEV_HASH}" --identifier "org.computerusex.app" "${APP_BUNDLE}"
    codesign --force --sign "${DEV_HASH}" "${DIST_DIR}/cux"
else
    echo "🔏 Signing bundle with ad-hoc signature..."
    codesign --force --sign - "${MACOS_DIR}/cux"
    codesign --force --sign - --identifier "org.computerusex.app" "${APP_BUNDLE}"
    codesign --force --sign - "${DIST_DIR}/cux"
fi

echo "✅ Build complete!"
echo "   • App Bundle : ${APP_BUNDLE}"
echo "   • CLI / MCP  : ${DIST_DIR}/cux"
echo ""
echo "🚀 Launch MenuBar HUD Daemon:"
echo "   open \"${APP_BUNDLE}\""
echo "🩺 Run Diagnostics:"
echo "   \"${DIST_DIR}/cux\" doctor"

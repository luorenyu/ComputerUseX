#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${ROOT_DIR}/dist"
APP_BUNDLE="${DIST_DIR}/OpenComputerUse.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

echo "🔨 Building OpenComputerUse (Release)..."
cd "${ROOT_DIR}"
swift build -c release

echo "📦 Packaging ${APP_BUNDLE}..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

cp "${ROOT_DIR}/Info.plist" "${CONTENTS_DIR}/Info.plist"
cp "${ROOT_DIR}/.build/release/OpenComputerUseApp" "${MACOS_DIR}/OpenComputerUseApp"
cp "${ROOT_DIR}/.build/release/ocu" "${MACOS_DIR}/ocu"
cp "${ROOT_DIR}/.build/release/ocu" "${DIST_DIR}/ocu"

chmod +x "${MACOS_DIR}/OpenComputerUseApp" "${MACOS_DIR}/ocu" "${DIST_DIR}/ocu"

echo "🔏 Signing bundle with ad-hoc signature for macOS TCC persistence..."
codesign --force --deep --sign - "${APP_BUNDLE}"
codesign --force --sign - "${DIST_DIR}/ocu"

echo "✅ Build complete!"
echo "   • App Bundle : ${APP_BUNDLE}"
echo "   • CLI / MCP  : ${DIST_DIR}/ocu"
echo ""
echo "🚀 Launch MenuBar HUD Daemon:"
echo "   open \"${APP_BUNDLE}\""
echo "🩺 Run Diagnostics:"
echo "   \"${DIST_DIR}/ocu\" doctor"

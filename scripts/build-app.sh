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
cp "${ROOT_DIR}/.build/release/ocu" "${DIST_DIR}/ocu"

chmod +x "${MACOS_DIR}/OpenComputerUseApp" "${DIST_DIR}/ocu"

# Prefer a stable Apple Development certificate if available so rebuilds keep macOS TCC permissions;
# otherwise fall back to ad-hoc signature.
DEV_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}' || true)"

if [[ -n "${DEV_IDENTITY}" ]]; then
    echo "🔏 Signing bundle with stable developer identity: ${DEV_IDENTITY}"
    codesign --force --sign "${DEV_IDENTITY}" --identifier "org.opencomputeruse.app" "${APP_BUNDLE}"
    codesign --force --sign "${DEV_IDENTITY}" "${DIST_DIR}/ocu"
else
    echo "🔏 Signing bundle with ad-hoc signature..."
    codesign --force --sign - --identifier "org.opencomputeruse.app" "${APP_BUNDLE}"
    codesign --force --sign - "${DIST_DIR}/ocu"
fi

echo "✅ Build complete!"
echo "   • App Bundle : ${APP_BUNDLE}"
echo "   • CLI / MCP  : ${DIST_DIR}/ocu"
echo ""
echo "🚀 Launch MenuBar HUD Daemon:"
echo "   open \"${APP_BUNDLE}\""
echo "🩺 Run Diagnostics:"
echo "   \"${DIST_DIR}/ocu\" doctor"

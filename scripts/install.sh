#!/usr/bin/env bash
set -euo pipefail

REPO_URL="https://github.com/luorenyu/ComputerUseX.git"
RELEASE_ZIP_URL="https://github.com/luorenyu/ComputerUseX/releases/latest/download/ComputerUseX-macos-arm64.zip"
INSTALL_BIN_DIR="${HOME}/.local/bin"

# Detect whether running inside a local checkout or via `curl -fsSL ... | bash`
SCRIPT_PATH="${BASH_SOURCE[0]:-}"
if [[ -n "${SCRIPT_PATH}" && -f "$(cd "$(dirname "${SCRIPT_PATH}")/.." 2>/dev/null && pwd)/Package.swift" ]]; then
    ROOT_DIR="$(cd "$(dirname "${SCRIPT_PATH}")/.." && pwd)"
    "${ROOT_DIR}/scripts/build-app.sh"
    SOURCE_DIST_DIR="${ROOT_DIR}/dist"
else
    TMP_WORK_DIR="$(mktemp -d /tmp/computerusex-install.XXXXXX)"
    trap 'rm -rf "${TMP_WORK_DIR}"' EXIT
    echo "⬇️  Installing ComputerUseX (cux)..."
    if curl -fsSLI "${RELEASE_ZIP_URL}" >/dev/null 2>&1; then
        echo "📦 Downloading prebuilt release bundle from GitHub Releases..."
        curl -fsSL "${RELEASE_ZIP_URL}" -o "${TMP_WORK_DIR}/release.zip"
        unzip -q "${TMP_WORK_DIR}/release.zip" -d "${TMP_WORK_DIR}"
        SOURCE_DIST_DIR="${TMP_WORK_DIR}"
    else
        echo "🔨 Cloning ${REPO_URL} and building locally with Swift 6..."
        git clone --depth 1 "${REPO_URL}" "${TMP_WORK_DIR}/ComputerUseX"
        "${TMP_WORK_DIR}/ComputerUseX/scripts/build-app.sh"
        SOURCE_DIST_DIR="${TMP_WORK_DIR}/ComputerUseX/dist"
    fi
fi

mkdir -p "${INSTALL_BIN_DIR}"

if [[ -w "/Applications" ]]; then
    killall ComputerUseXApp OpenComputerUseApp 2>/dev/null || true
    rm -rf "/Applications/OpenComputerUse.app" "/Applications/ComputerUseX.app"
    cp -R "${SOURCE_DIST_DIR}/ComputerUseX.app" "/Applications/ComputerUseX.app"
    ln -sf "/Applications/ComputerUseX.app/Contents/MacOS/cux" "${INSTALL_BIN_DIR}/cux"
    echo "🎉 Installed 'ComputerUseX.app' to /Applications/ComputerUseX.app"
else
    cp "${SOURCE_DIST_DIR}/cux" "${INSTALL_BIN_DIR}/cux"
    chmod +x "${INSTALL_BIN_DIR}/cux"
fi

echo "🎉 Installed 'cux' to ${INSTALL_BIN_DIR}/cux"
"${INSTALL_BIN_DIR}/cux" install-mcp all || true
open -g "/Applications/ComputerUseX.app" 2>/dev/null || true

echo "📌 MCP Server Configuration (Antigravity / Claude / Codex / Cursor / Windsurf):"
cat <<EOF
{
  "mcpServers": {
    "computer-use-x": {
      "command": "${INSTALL_BIN_DIR}/cux",
      "args": ["mcp"]
    }
  }
}
EOF

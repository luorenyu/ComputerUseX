#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"${ROOT_DIR}/scripts/build-app.sh"

INSTALL_BIN_DIR="${HOME}/.local/bin"
mkdir -p "${INSTALL_BIN_DIR}"
ln -sf "${ROOT_DIR}/dist/cux" "${INSTALL_BIN_DIR}/cux"

if [[ -w "/Applications" ]]; then
    rm -rf "/Applications/OpenComputerUse.app" "/Applications/ComputerUseX.app"
    cp -R "${ROOT_DIR}/dist/ComputerUseX.app" "/Applications/ComputerUseX.app"
    echo "🎉 Installed 'ComputerUseX.app' to /Applications/ComputerUseX.app"
fi

echo "🎉 Installed 'cux' to ${INSTALL_BIN_DIR}/cux"
"${INSTALL_BIN_DIR}/cux" install-mcp all || true

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

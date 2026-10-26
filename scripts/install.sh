#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"${ROOT_DIR}/scripts/build-app.sh"

INSTALL_BIN_DIR="${HOME}/.local/bin"
mkdir -p "${INSTALL_BIN_DIR}"
ln -sf "${ROOT_DIR}/dist/ocu" "${INSTALL_BIN_DIR}/ocu"

if [[ -w "/Applications" ]]; then
    rm -rf "/Applications/OpenComputerUse.app"
    cp -R "${ROOT_DIR}/dist/OpenComputerUse.app" "/Applications/OpenComputerUse.app"
    echo "🎉 Installed 'OpenComputerUse.app' to /Applications/OpenComputerUse.app"
fi

echo "🎉 Installed 'ocu' to ${INSTALL_BIN_DIR}/ocu"
echo "📌 MCP Server Configuration (Antigravity / Claude / Cursor / Windsurf):"
cat <<EOF
{
  "mcpServers": {
    "open-computer-use": {
      "command": "${INSTALL_BIN_DIR}/ocu",
      "args": ["mcp"]
    }
  }
}
EOF

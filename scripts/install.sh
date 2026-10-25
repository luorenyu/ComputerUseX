#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"${ROOT_DIR}/scripts/build-app.sh"

INSTALL_BIN_DIR="${HOME}/.local/bin"
mkdir -p "${INSTALL_BIN_DIR}"
ln -sf "${ROOT_DIR}/dist/ocu" "${INSTALL_BIN_DIR}/ocu"

echo ""
echo "🎉 Installed 'ocu' to ${INSTALL_BIN_DIR}/ocu"
echo "📌 MCP Server Configuration (Antigravity / Claude / Cursor):"
cat <<EOF
{
  "mcpServers": {
    "open-computer-use": {
      "command": "${ROOT_DIR}/dist/ocu",
      "args": ["mcp"]
    }
  }
}
EOF

#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Restoring Flatpak apps ==="
xargs flatpak install -y < "$SCRIPT_DIR/flatpak-apps.txt"

echo ""
echo "=== Creating default toolbox ==="
toolbox create fedora-toolbox-43 || true

echo ""
echo "=== Installing toolbox packages ==="
toolbox run --container fedora-toolbox-43 sudo dnf install -y \
    $(cat "$SCRIPT_DIR/toolbox-fedora-43-packages.txt" | tr '\n' ' ')

echo ""
echo "=== Creating micropython-dev toolbox ==="
toolbox create micropython-dev || true

echo ""
echo "=== Done ==="
echo "You may need to configure git and gh inside the toolbox:"
echo "  toolbox run git config --global user.name 'Your Name'"
echo "  toolbox run git config --global user.email 'your@email'"
echo "  toolbox run gh auth login"

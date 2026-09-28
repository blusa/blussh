#!/bin/bash
# Install the blussh Omarchy shell widget.
#
#   omarchy/install.sh           copy the plugin into ~/.config/omarchy/plugins
#   omarchy/install.sh --link    symlink it instead (development: edits hot-reload)
#
# Also puts a `blussh` command on PATH for the backend's CLI
# (zerotier-token, zerotier-authtoken, check, set).

set -euo pipefail

src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
id="$(jq -r .id "$src/manifest.json")"
target="$HOME/.config/omarchy/plugins/$id"

omarchy plugin validate "$src"
mkdir -p "$(dirname "$target")" "$HOME/.local/bin"
rm -rf "$target"

if [[ ${1:-} == --link ]]; then
  ln -s "$src" "$target"
else
  mkdir -p "$target"
  cp "$src"/manifest.json "$src"/*.qml "$src"/blussh.py "$src"/README.md "$target"/
fi
chmod +x "$target/blussh.py"
ln -sf "$target/blussh.py" "$HOME/.local/bin/blussh"

omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
# The rescan is asynchronous; wait for the shell to learn about the plugin
for _ in {1..20}; do
  omarchy plugin enable "$id" >/dev/null 2>&1 && break
  sleep 0.5
done
echo "blussh installed at $target and added to the bar."

#!/bin/bash
# Emit the Homebrew cask for a release to stdout.
# Usage: scripts/make-cask.sh <version> <sha256>
set -euo pipefail

VERSION=${1:?usage: make-cask.sh <version> <sha256>}
SHA256=${2:?usage: make-cask.sh <version> <sha256>}

cat <<EOF
cask "blussh" do
  version "${VERSION}"
  sha256 "${SHA256}"

  url "https://github.com/blusa/blussh/releases/download/v#{version}/blussh-v#{version}.zip"
  name "blussh"
  desc "Menu bar app that monitors host connectivity across SSH config, Tailscale, and ZeroTier"
  homepage "https://github.com/blusa/blussh"

  depends_on macos: :sequoia

  app "blussh.app"

  # Homebrew 6 dropped --no-quarantine, and a quarantined app that was never
  # manually approved is silently refused when launchd starts it at login
  # (the launch dies as xpcproxy). The app is notarized, so Gatekeeper has
  # already vouched for it; drop the flag so launch-at-login works.
  postflight_steps do
    run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "{{appdir}}/blussh.app"]
  end

  zap trash: "~/Library/Preferences/cloud.blusa.blussh.plist"
end
EOF

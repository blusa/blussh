#!/bin/bash
# Release blussh to GitHub Releases and update the Homebrew tap.
#
# Usage: scripts/release.sh <version>          e.g. scripts/release.sh 1.0.1
#
# Requires: gh (authenticated), xcodebuild. No CI secrets involved.
set -euo pipefail

VERSION=${1:?usage: scripts/release.sh <version>}
REPO="blusa/blussh"
TAP_REPO="blusa/homebrew-tap"
TAG="v${VERSION}"

cd "$(dirname "$0")/.."

if [[ -n "$(git status --porcelain)" ]]; then
  echo "error: working tree not clean" >&2
  exit 1
fi

# Keep the app's version in sync with the tag
if ! grep -q "MARKETING_VERSION = ${VERSION};" blussh.xcodeproj/project.pbxproj; then
  sed -i '' "s/MARKETING_VERSION = [^;]*;/MARKETING_VERSION = ${VERSION};/g" blussh.xcodeproj/project.pbxproj
  git add blussh.xcodeproj/project.pbxproj
  git commit -m "Bump version to ${VERSION}"
fi

echo "==> Building Release"
xcodebuild -project blussh.xcodeproj -scheme blussh -configuration Release build -quiet
BUILT=$(xcodebuild -project blussh.xcodeproj -scheme blussh -configuration Release -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR/{print $3}')

ZIP="/tmp/blussh-${TAG}.zip"
ditto -c -k --keepParent "${BUILT}/blussh.app" "$ZIP"
SHA256=$(shasum -a 256 "$ZIP" | awk '{print $1}')
echo "==> ${ZIP} (sha256 ${SHA256})"

echo "==> Tagging and creating GitHub release ${TAG}"
git tag "$TAG"
git push origin HEAD "$TAG"
gh release create "$TAG" "$ZIP" --repo "$REPO" --title "$TAG" \
  --generate-notes

echo "==> Updating cask in ${TAP_REPO}"
TAP_DIR=$(mktemp -d)
gh repo clone "$TAP_REPO" "$TAP_DIR" -- --depth 1
mkdir -p "$TAP_DIR/Casks"
cat > "$TAP_DIR/Casks/blussh.rb" <<EOF
cask "blussh" do
  version "${VERSION}"
  sha256 "${SHA256}"

  url "https://github.com/${REPO}/releases/download/v#{version}/blussh-v#{version}.zip"
  name "blussh"
  desc "Menu bar app that monitors host connectivity across SSH config, Tailscale, and ZeroTier"
  homepage "https://github.com/${REPO}"

  depends_on macos: ">= :sequoia"

  app "blussh.app"

  caveats <<~EOS
    blussh is not notarized. Install with:
      brew install --no-quarantine blusa/tap/blussh
    or clear the quarantine flag after install:
      xattr -dr com.apple.quarantine /Applications/blussh.app
  EOS

  zap trash: "~/Library/Preferences/cloud.blusa.blussh.plist"
end
EOF
git -C "$TAP_DIR" add Casks/blussh.rb
git -C "$TAP_DIR" commit -m "blussh ${VERSION}"
git -C "$TAP_DIR" push
rm -rf "$TAP_DIR"

echo "==> Done: brew install --no-quarantine blusa/tap/blussh"

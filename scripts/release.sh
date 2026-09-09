#!/bin/bash
# Kick off a release: bump the version, tag, and push.
# The Release GitHub Action (.github/workflows/release.yml) then builds the
# app, publishes the GitHub release, and updates the cask in blusa/homebrew-tap.
#
# Usage: scripts/release.sh <version>          e.g. scripts/release.sh 1.0.1
set -euo pipefail

VERSION=${1:?usage: scripts/release.sh <version>}
TAG="v${VERSION}"

cd "$(dirname "$0")/.."

if [[ -n "$(git status --porcelain)" ]]; then
  echo "error: working tree not clean" >&2
  exit 1
fi

if ! grep -q "MARKETING_VERSION = ${VERSION};" blussh.xcodeproj/project.pbxproj; then
  sed -i '' "s/MARKETING_VERSION = [^;]*;/MARKETING_VERSION = ${VERSION};/g" blussh.xcodeproj/project.pbxproj
  git add blussh.xcodeproj/project.pbxproj
  git commit -m "Bump version to ${VERSION}"
fi

git tag "$TAG"
git push origin HEAD "$TAG"

echo "==> Pushed ${TAG}; the Release action takes it from here:"
echo "    gh run watch --repo blusa/blussh"

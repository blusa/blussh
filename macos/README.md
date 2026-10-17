# blussh for macOS

SwiftUI menu bar app. Install with `brew install blusa/tap/blussh`; see the
[main README](../README.md) for features.

The cask strips `com.apple.quarantine` after installing. The app is notarized,
so Gatekeeper has already vouched for it, and a quarantined bundle that was
never manually approved is silently refused when launchd starts it at login.

## Build

```bash
cd macos
xcodebuild -project blussh.xcodeproj -scheme blussh -configuration Release build
```

Not sandboxed (it execs the tailscale CLI and reads ZeroTier's authtoken).
The ZeroTier Central API token is stored in the Keychain.

## Release

```bash
macos/scripts/release.sh 1.0.1
```

The script bumps `MARKETING_VERSION` (committing if needed) and pushes the
`v1.0.1` tag. Pushing any `v*` tag triggers the
[Release action](../.github/workflows/release.yml), which runs from `macos/`
and:

1. builds the app on a macOS runner with hardened runtime and signs it with
   the "Developer ID Application: Pablo Pusiol" certificate (secrets
   `SIGNING_CERT_P12` / `SIGNING_CERT_P12_PASSWORD`; expires 2027-02, renew
   via the developer portal with the CSR in `~/.keys` on Buster),
2. notarizes the zip with `notarytool` (App Store Connect API key secrets
   `ASC_API_KEY_P8` / `ASC_KEY_ID` / `ASC_ISSUER_ID`) and staples the ticket,
3. publishes `blussh-v<version>.zip` as a GitHub release with generated notes,
4. regenerates `Casks/blussh.rb` (template: `scripts/make-cask.sh`) and pushes
   it to [blusa/homebrew-tap](https://github.com/blusa/homebrew-tap).

Cross-repo push uses a write deploy key on the tap, stored as the
`TAP_DEPLOY_KEY` secret in this repo. Watch a run with `gh run watch`.

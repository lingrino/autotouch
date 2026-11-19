#!/bin/bash
# Build a Autotouch release and the Homebrew cask that installs it (what CI publishes).
#   scripts/release.sh  →  build/release/Autotouch.app, Autotouch-<version>.zip, autotouch.rb, version
#
# Version and signing: see bundle.sh (AUTOTOUCH_SIGN_IDENTITY; "-" for an unsigned dry run).
# Notarization runs when an App Store Connect API key is given: AUTOTOUCH_NOTARY_KEY (path to
# the .p8), AUTOTOUCH_NOTARY_KEY_ID, AUTOTOUCH_NOTARY_ISSUER. The ticket is stapled to the app
# before zipping, so Gatekeeper accepts it offline.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=build/release
rm -rf "$OUT"
mkdir -p "$OUT"

./scripts/swift.sh build -c release --product Autotouch
./scripts/bundle.sh release "$OUT/Autotouch.app"
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$OUT/Autotouch.app/Contents/Info.plist")"
ZIP="$OUT/Autotouch-$VERSION.zip"
codesign --verify --strict --deep "$OUT/Autotouch.app"

if [[ -n "${AUTOTOUCH_NOTARY_KEY:-}" ]]; then
  ditto -c -k --keepParent "$OUT/Autotouch.app" "$OUT/notarize.zip"
  result="$(xcrun notarytool submit "$OUT/notarize.zip" --wait --output-format json \
    --key "$AUTOTOUCH_NOTARY_KEY" --key-id "$AUTOTOUCH_NOTARY_KEY_ID" --issuer "$AUTOTOUCH_NOTARY_ISSUER")"
  echo "$result"
  rm "$OUT/notarize.zip"
  if [[ "$(jq -r .status <<<"$result")" != Accepted ]]; then
    xcrun notarytool log "$(jq -r .id <<<"$result")" \
      --key "$AUTOTOUCH_NOTARY_KEY" --key-id "$AUTOTOUCH_NOTARY_KEY_ID" --issuer "$AUTOTOUCH_NOTARY_ISSUER" || true
    echo "release: notarization failed" >&2
    exit 1
  fi
  xcrun stapler staple "$OUT/Autotouch.app"
  spctl --assess --type execute --verbose "$OUT/Autotouch.app"
fi

ditto -c -k --keepParent "$OUT/Autotouch.app" "$ZIP"
SHA="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"

# Upgrades: brew swaps /Applications/Autotouch.app; the agent sees its executable replaced and
# exits, and launchd starts the new one (KeepAlive; RestartWhenReplaced in Agent.swift). No
# `uninstall launchctl:`: brew runs uninstall stanzas on every upgrade too, and only opening
# Autotouch.app registers the agent again; `zap` removes it. A fresh install needs Autotouch.app
# opened once (it registers the agent and exits). The macOS minimum is
# LSMinimumSystemVersion's job.
cat > "$OUT/autotouch.rb" <<EOF
cask "autotouch" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://github.com/lingrino/autotouch/releases/download/v#{version}/Autotouch-#{version}.zip"
  name "Autotouch"
  desc "Three-finger trackpad swipes: open Chrome, hide the app under the pointer"
  homepage "https://github.com/lingrino/autotouch"

  depends_on arch: :arm64

  app "Autotouch.app"

  zap launchctl: "com.lingrino.autotouch.agent"
end
EOF
echo "$VERSION" > "$OUT/version"
echo "release: $ZIP ($SHA)"

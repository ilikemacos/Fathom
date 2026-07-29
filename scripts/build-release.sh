#!/bin/bash
# Build Fathom .app + ZIP/PKG/DMG + sync installers into dist/ and optional HQ path.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
VER_LABEL="v0.1.1-Beta"
SHORT="0.1.1"
HQ_OUT="${1:-}"

echo "Building Fathom $VER_LABEL…"
rm -rf "$DIST"
mkdir -p "$DIST/staging"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fathom-rel.XXXXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT
cp "$ROOT/Sources/FathomApp.swift" "$WORK/main.swift"
swiftc "$WORK/main.swift" -o "$WORK/Fathom" \
  -framework SwiftUI -framework Cocoa -framework IOKit \
  -parse-as-library -O
strip -x "$WORK/Fathom" 2>/dev/null || true

APP="$DIST/staging/Fathom.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$WORK/Fathom" "$APP/Contents/MacOS/Fathom"
chmod 755 "$APP/Contents/MacOS/Fathom"
cat > "$APP/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Fathom</string>
    <key>CFBundleIdentifier</key><string>com.chopstickshq.fathom</string>
    <key>CFBundleName</key><string>Fathom</string>
    <key>CFBundleDisplayName</key><string>Fathom</string>
    <key>CFBundleVersion</key><string>${SHORT}</string>
    <key>CFBundleShortVersionString</key><string>${SHORT}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><false/>
</dict>
</plist>
PLIST
codesign --force --deep --sign - "$APP" 2>/dev/null || true
xattr -cr "$APP" 2>/dev/null || true

(cd "$DIST/staging" && zip -qry "$DIST/Fathom-${VER_LABEL}.zip" Fathom.app)

DMG_STAGING="$(mktemp -d)"
cp -R "$APP" "$DMG_STAGING/Fathom.app"
ln -sf /Applications "$DMG_STAGING/Applications"
hdiutil create -volname "Fathom" -srcfolder "$DMG_STAGING" -ov -format UDZO \
  "$DIST/Fathom-${VER_LABEL}.dmg" >/dev/null
rm -rf "$DMG_STAGING"

PKG_ROOT="$(mktemp -d)"
mkdir -p "$PKG_ROOT/Applications"
cp -R "$APP" "$PKG_ROOT/Applications/Fathom.app"
pkgbuild --root "$PKG_ROOT" --identifier com.chopstickshq.fathom \
  --version "$SHORT" --install-location / \
  "$DIST/Fathom-${VER_LABEL}.pkg" >/dev/null
rm -rf "$PKG_ROOT"

# Versioned sh copies (assume install-fathom.sh already hashed)
cp -f "$ROOT/install-fathom.sh" "$DIST/install-fathom.sh"
cp -f "$ROOT/install-fathom.sh" "$DIST/Fathom-${VER_LABEL}.sh"
cp -f "$ROOT/install-fathom.sh" "$DIST/Fathom-v0.1.1-Experimental.sh"
cp -f "$ROOT/version.json" "$DIST/"
cp -f "$ROOT/changelog.json" "$DIST/"
# experimental mirrors of packages
cp -f "$DIST/Fathom-${VER_LABEL}.zip" "$DIST/Fathom-v0.1.1-Experimental.zip"
cp -f "$DIST/Fathom-${VER_LABEL}.dmg" "$DIST/Fathom-v0.1.1-Experimental.dmg"
cp -f "$DIST/Fathom-${VER_LABEL}.pkg" "$DIST/Fathom-v0.1.1-Experimental.pkg"

python3 - <<PY
import hashlib, json, re
from pathlib import Path
root = Path(r"$ROOT")
dist = root / "dist"
sh = (dist / "Fathom-v0.1.1-Beta.sh").read_text()
masked = re.sub(r'^EXPECTED_HASH=.*$', 'EXPECTED_HASH="MASKED"', sh, flags=re.M)
ver = json.loads((root / "version.json").read_text())
ver["hashes"] = {
    "beta_sh": hashlib.sha256(masked.encode()).hexdigest(),
    "beta_pkg": hashlib.sha256((dist / "Fathom-v0.1.1-Beta.pkg").read_bytes()).hexdigest(),
    "beta_dmg": hashlib.sha256((dist / "Fathom-v0.1.1-Beta.dmg").read_bytes()).hexdigest(),
    "beta_zip": hashlib.sha256((dist / "Fathom-v0.1.1-Beta.zip").read_bytes()).hexdigest(),
}
(root / "version.json").write_text(json.dumps(ver, indent=2) + "\n")
(dist / "version.json").write_text(json.dumps(ver, indent=2) + "\n")
print("hashes", ver["hashes"])
PY

if [[ -n "$HQ_OUT" ]]; then
  mkdir -p "$HQ_OUT"
  cp -f "$DIST"/Fathom-v0.1.1-Beta.{sh,pkg,dmg,zip} "$HQ_OUT/"
  cp -f "$DIST"/Fathom-v0.1.1-Experimental.{sh,pkg,dmg,zip} "$HQ_OUT/" 2>/dev/null || true
  cp -f "$DIST/version.json" "$HQ_OUT/"
  cp -f "$DIST/changelog.json" "$HQ_OUT/"
  cp -f "$DIST/install-fathom.sh" "$HQ_OUT/"
  cp -f "$DIST/Fathom-v0.1.1-Beta.sh" "$HQ_OUT/install.sh"
  echo "Synced to $HQ_OUT"
fi

echo "Done → $DIST"
ls -lah "$DIST"

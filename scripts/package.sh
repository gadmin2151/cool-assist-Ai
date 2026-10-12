#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "${1:-}" != "--skip-build" ]; then bash scripts/build-app.sh; fi
APP="dist/Cool Assist Ai.app"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
PACKAGE="dist/CoolAssistAi-${VERSION}-AppleSilicon.pkg"
DISK_IMAGE="dist/CoolAssistAi-${VERSION}-AppleSilicon.dmg"
CHECKSUMS="dist/CoolAssistAi-${VERSION}-macOS-SHA256SUMS.txt"
codesign --verify --deep --strict "$APP"
STAGE=$(mktemp -d "$PWD/dist/mac-stage.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/root" "$STAGE/packages" "$STAGE/dmg"
# APFS clones keep bundled local models from consuming several duplicate gigabytes.
cp -cR "$APP" "$STAGE/root/"
pkgbuild --root "$STAGE/root" --component-plist Resources/Components.plist \
    --install-location /Applications --identifier cc.idomus.meet-secretar --version "$VERSION" \
    "$STAGE/packages/CoolAssistAi-component.pkg"
# Derive the distribution version from the actual bundle to prevent stale installer metadata.
python3 - "$VERSION" "$STAGE/Distribution.xml" <<'PY'
import sys
import xml.etree.ElementTree as ET
root = ET.parse("Resources/Distribution.xml")
root.find("title").text = "Cool Assist Ai " + sys.argv[1]
for reference in root.findall("pkg-ref"):
    reference.set("version", sys.argv[1])
root.write(sys.argv[2], encoding="utf-8", xml_declaration=True)
PY
productbuild --distribution "$STAGE/Distribution.xml" --package-path "$STAGE/packages" \
    "$STAGE/CoolAssistAi.pkg"
mv "$STAGE/CoolAssistAi.pkg" "$PACKAGE"
# The intermediate component is no longer needed before the DMG compression starts.
rm "$STAGE/packages/CoolAssistAi-component.pkg"
PACKAGE_OUTPUTS=("$PACKAGE")
if [ -n "${INSTALLER_IDENTITY:-}" ]; then
    SIGNED_PACKAGE="${PACKAGE%.pkg}-signed.pkg"
    productsign --sign "$INSTALLER_IDENTITY" "$PACKAGE" "$SIGNED_PACKAGE"
    pkgutil --check-signature "$SIGNED_PACKAGE"
    PACKAGE_OUTPUTS+=("$SIGNED_PACKAGE")
else
    printf '%s\n' 'Installer package is unsigned: set INSTALLER_IDENTITY for Developer ID Installer signing.'
fi
cp -cR "$APP" "$STAGE/dmg/"
ln -s /Applications "$STAGE/dmg/Applications"
cat > "$STAGE/dmg/INSTALL.txt" <<'TXT'
Cool Assist Ai for macOS (Apple Silicon, macOS 15 or later)

Quit any running Cool Assist Ai or Meet Protocol application.
Drag Cool Assist Ai.app into Applications and open it there.
If replacing Meet Protocol, remove its old application after confirming the new version opens.
Your existing meetings and settings use the same storage location and are preserved.

The app contains local speech and summary models. An OpenAI API key is optional for cloud summaries.
Personal local builds are not Apple-notarized. Distributable releases require Developer ID signing and notarization.
TXT
hdiutil create -volname 'Cool Assist Ai' -srcfolder "$STAGE/dmg" -fs HFS+ \
    -format ULFO -ov "$DISK_IMAGE"
hdiutil verify "$DISK_IMAGE"
(cd dist && shasum -a 256 "${PACKAGE_OUTPUTS[@]#dist/}" "${DISK_IMAGE#dist/}") > "$CHECKSUMS"
printf 'Created %s\nCreated %s\nChecksums %s\n' "$PACKAGE" "$DISK_IMAGE" "$CHECKSUMS"

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="$SCRIPT_DIR/out"

SIGNING_IDENTITY="Developer ID Application: Fishball Ltd (9CWXH66CKT)"
TEAM_ID="9CWXH66CKT"

echo "=== DirBuff Mac Release Build ==="

# Check secrets
if [[ -z "${ASC_API_KEY_P8_BASE64:-}" || -z "${ASC_KEY_ID:-}" || -z "${ASC_ISSUER_ID:-}" ]]; then
  echo "Error: App Store Connect API key credentials (ASC_API_KEY_P8_BASE64, ASC_KEY_ID, ASC_ISSUER_ID) are missing." >&2
  echo "Run it through varlock, which loads them from 1Password: pnpm -F @dirbuff/mac exec varlock run -- ./release.sh" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d -t dirbuff-release-XXXXXX)"
cleanup() {
  echo "Cleaning up temporary directory..."
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

# Write API key to temp file
KEY_PATH="$TMP_DIR/AuthKey_${ASC_KEY_ID}.p8"
echo "$ASC_API_KEY_P8_BASE64" | base64 -d > "$KEY_PATH"
chmod 600 "$KEY_PATH"

# Both are bumped by hand in the release's pull request. A dev build of main sets
# DIRBUFF_VERSION and DIRBUFF_BUILD instead (release/publish.ts --check --dev computes them).
MARKETING_VERSION="${DIRBUFF_VERSION:-}"
if [[ -z "$MARKETING_VERSION" ]]; then
  MARKETING_VERSION=$(sed -n 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"\([^"]*\)".*/\1/p' "$SCRIPT_DIR/project.yml")
fi
if [[ -z "$MARKETING_VERSION" ]]; then
  echo "Error: Could not extract MARKETING_VERSION from $SCRIPT_DIR/project.yml" >&2
  exit 1
fi
CURRENT_PROJECT_VERSION="${DIRBUFF_BUILD:-}"
if [[ -z "$CURRENT_PROJECT_VERSION" ]]; then
  CURRENT_PROJECT_VERSION=$(sed -n 's/^[[:space:]]*CURRENT_PROJECT_VERSION:[[:space:]]*"\([^"]*\)".*/\1/p' "$SCRIPT_DIR/project.yml")
fi
if [[ -z "$CURRENT_PROJECT_VERSION" ]]; then
  echo "Error: Could not extract CURRENT_PROJECT_VERSION from $SCRIPT_DIR/project.yml" >&2
  exit 1
fi

echo "Version: $MARKETING_VERSION (Build $CURRENT_PROJECT_VERSION)"

# 1. XcodeGen
echo "--> Generating Xcode project..."
xcodegen generate --spec "$SCRIPT_DIR/project.yml" --project "$SCRIPT_DIR"

# 2. Xcode archive
ARCHIVE_PATH="$TMP_DIR/DirBuff.xcarchive"
DERIVED_DATA_PATH="$TMP_DIR/DerivedData"
CLONED_SOURCE_PACKAGES_DIR_PATH="$TMP_DIR/SourcePackages"
echo "--> Archiving DirBuff..."
xcodebuild -project "$SCRIPT_DIR/DirBuff.xcodeproj" \
  -scheme DirBuff \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -clonedSourcePackagesDirPath "$CLONED_SOURCE_PACKAGES_DIR_PATH" \
  -xcconfig "$SCRIPT_DIR/PolarProduction.xcconfig" \
  CURRENT_PROJECT_VERSION="$CURRENT_PROJECT_VERSION" \
  MARKETING_VERSION="$MARKETING_VERSION" \
  DIRBUFF_RELEASE_DATE="$(date -u +%Y-%m-%d)" \
  CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_STYLE="Manual" \
  ENABLE_HARDENED_RUNTIME="YES" \
  archive

# 3. Export archive
EXPORT_DIR="$TMP_DIR/export"
echo "--> Exporting archive..."
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -xcconfig "$SCRIPT_DIR/PolarProduction.xcconfig" \
  -exportOptionsPlist "$SCRIPT_DIR/ExportOptions.plist" \
  -exportPath "$EXPORT_DIR"

APP_PATH="$EXPORT_DIR/DirBuff.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "Error: Exported DirBuff.app not found at $APP_PATH" >&2
  exit 1
fi

# 4. Deep code sign verification
echo "--> Verifying code signature of DirBuff.app and embedded components..."
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

# 5. Notarise App
echo "--> Creating app zip for notarisation..."
APP_ZIP="$TMP_DIR/DirBuff.zip"
ditto -c -k --keepParent "$APP_PATH" "$APP_ZIP"

echo "--> Submitting DirBuff.app for notarisation..."
xcrun notarytool submit "$APP_ZIP" \
  --key "$KEY_PATH" \
  --key-id "$ASC_KEY_ID" \
  --issuer "$ASC_ISSUER_ID" \
  --wait

echo "--> Stapling notarisation ticket to DirBuff.app..."
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"

echo "--> Assessing stapled app with spctl..."
spctl --assess --type exec -v "$APP_PATH"

# 6. DMG Creation
echo "--> Preparing DMG staging directory..."
DMG_STAGING="$TMP_DIR/dmg-staging"
mkdir -p "$DMG_STAGING"
cp -R "$APP_PATH" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"

DMG_FILENAME="DirBuff-${MARKETING_VERSION}.dmg"
RAW_DMG="$TMP_DIR/$DMG_FILENAME"
echo "--> Building disk image ($RAW_DMG)..."
hdiutil create -volname "DirBuff" -srcfolder "$DMG_STAGING" -ov -format UDZO "$RAW_DMG"

echo "--> Signing disk image..."
codesign --force --sign "$SIGNING_IDENTITY" --timestamp "$RAW_DMG"
codesign --verify --verbose=2 "$RAW_DMG"

echo "--> Submitting DMG for notarisation..."
xcrun notarytool submit "$RAW_DMG" \
  --key "$KEY_PATH" \
  --key-id "$ASC_KEY_ID" \
  --issuer "$ASC_ISSUER_ID" \
  --wait

echo "--> Stapling disk image..."
xcrun stapler staple "$RAW_DMG"
xcrun stapler validate "$RAW_DMG"

# 7. Quarantine Verification
echo "--> Performing quarantine Gatekeeper checks..."
QUARANTINE_DIR="$TMP_DIR/quarantine-test"
mkdir -p "$QUARANTINE_DIR"
DMG_COPY="$QUARANTINE_DIR/$DMG_FILENAME"
cp "$RAW_DMG" "$DMG_COPY"
xattr -w com.apple.quarantine "0083;00000000;Safari;" "$DMG_COPY"

echo "--> Verifying quarantined DMG..."
spctl --assess --type open --context context:primary-signature -v "$DMG_COPY"

echo "--> Verifying quarantined app inside DMG..."
MOUNT_POINT="$TMP_DIR/mnt"
mkdir -p "$MOUNT_POINT"
hdiutil attach "$DMG_COPY" -mountpoint "$MOUNT_POINT" -nobrowse -readonly
APP_COPY="$QUARANTINE_DIR/DirBuff.app"
cp -R "$MOUNT_POINT/DirBuff.app" "$APP_COPY"
hdiutil detach "$MOUNT_POINT"
xattr -w com.apple.quarantine "0083;00000000;Safari;" "$APP_COPY"
spctl --assess --type exec -v "$APP_COPY"

# 8. Copy to output
mkdir -p "$OUT_DIR"
FINAL_DMG="$OUT_DIR/$DMG_FILENAME"
cp "$RAW_DMG" "$FINAL_DMG"

echo "--> Copying Sparkle sign_update tool to $OUT_DIR/sign_update..."
cp "$CLONED_SOURCE_PACKAGES_DIR_PATH/artifacts/sparkle/Sparkle/bin/sign_update" "$OUT_DIR/sign_update"
chmod +x "$OUT_DIR/sign_update"

echo "=== Release Build Successful ==="
echo "Artifact: $FINAL_DMG"
ls -lh "$FINAL_DMG"

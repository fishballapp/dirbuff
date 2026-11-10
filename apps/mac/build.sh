#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

SIGNING_IDENTITY="Developer ID Application: Fishball Ltd (9CWXH66CKT)"
TEAM_ID="9CWXH66CKT"
OUT_DIR="$SCRIPT_DIR/out"
DERIVED_DATA="$SCRIPT_DIR/.derivedData"

mkdir -p "$OUT_DIR"

echo "=========================================================="
echo " Building DirBuff macOS App (Release)"
echo "=========================================================="

# The Developer ID certificate comes from 1Password through varlock, into a keychain that lasts
# as long as this script (signing-keychain.sh). Run it as `pnpm -F @dirbuff/mac with-secrets --
# ./build.sh`. OTHER_CODE_SIGN_FLAGS splits on spaces, so a $TMPDIR with a space in it fails the
# signing step; accepted, macOS's never has one.
source "$SCRIPT_DIR/signing-keychain.sh"
open_signing_keychain

echo "0. Building the pinned restic..."
"$SCRIPT_DIR/restic/build.sh"

echo "1. Generating Xcode project with XcodeGen..."
xcodegen generate --spec "$SCRIPT_DIR/project.yml" --project "$SCRIPT_DIR"

echo "2. Building DirBuff application..."
xcodebuild -project "$SCRIPT_DIR/DirBuff.xcodeproj" \
    -scheme "DirBuff" \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    CODE_SIGN_STYLE="Manual" \
    DIRBUFF_GOOGLE_CLIENT_SECRET="$GOOGLE_OAUTH_CLIENT_SECRET" \
    OTHER_CODE_SIGN_FLAGS="--keychain $SIGNING_KEYCHAIN" \
    ENABLE_HARDENED_RUNTIME=YES \
    build

echo "3. Copying built product to $OUT_DIR..."
rm -rf "$OUT_DIR/DirBuff.app"
PRODUCTS_DIR="$DERIVED_DATA/Build/Products/Release"
cp -R "$PRODUCTS_DIR/DirBuff.app" "$OUT_DIR/DirBuff.app"

echo "4. Verifying codesign signature and entitlements..."
codesign -dv --verbose=2 "$OUT_DIR/DirBuff.app"
codesign --verify --deep --strict "$OUT_DIR/DirBuff.app"
codesign -dv "$OUT_DIR/DirBuff.app/Contents/Helpers/restic" 2>&1 | grep -E "Identifier|flags|Timestamp"

echo "=========================================================="
echo " Build and signature verification successful!"
echo " Output: $OUT_DIR/DirBuff.app"
echo "=========================================================="

#!/usr/bin/env bash
set -euo pipefail

# Resolve repo root relative to script location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_DIR="$REPO_ROOT/app"
DIST_DIR="$REPO_ROOT/dist"

# Defaults
VERSION=""
SIGN_IDENTITY=""
NOTARIZE_PROFILE=""

show_help() {
    cat <<'EOF'
Usage: build-dmg.sh [OPTIONS]

Build TokenWatch.app and create a DMG disk image.

Options:
  --version X          Stamp version X into Info.plist (default: read from existing CFBundleShortVersionString)
  --sign IDENTITY      Codesign with Developer ID identity (hardened runtime + timestamp, then verify)
  --notarize-profile P Notarize with notarytool profile (requires --sign)
  -h, --help           Show this help message

EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)
            VERSION="$2"
            shift 2
            ;;
        --sign)
            SIGN_IDENTITY="$2"
            shift 2
            ;;
        --notarize-profile)
            NOTARIZE_PROFILE="$2"
            shift 2
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            show_help
            exit 1
            ;;
    esac
done

# Require notarize profile only if sign is set
if [[ -n "$NOTARIZE_PROFILE" && -z "$SIGN_IDENTITY" ]]; then
    echo "Error: --notarize-profile requires --sign" >&2
    exit 1
fi

# Create dist directory
mkdir -p "$DIST_DIR"

# Determine version
if [[ -z "$VERSION" ]]; then
    INFO_PLIST="$APP_DIR/Sources/TokenWatch/Info.plist"
    if [[ ! -f "$INFO_PLIST" ]]; then
        echo "Error: Info.plist not found at $INFO_PLIST" >&2
        exit 1
    fi
    VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$INFO_PLIST" 2>/dev/null || true)
    if [[ -z "$VERSION" ]]; then
        echo "Error: CFBundleShortVersionString is empty in $INFO_PLIST and --version not provided" >&2
        exit 1
    fi
fi

DMG_NAME="TokenWatch-$VERSION.dmg"
APP_BUNDLE="$DIST_DIR/TokenWatch.app"
DMG_PATH="$DIST_DIR/$DMG_NAME"

# Prune module-cache directories (they upset fresh toolchains)
find "$APP_DIR/.build" -type d -name "module-cache" -mindepth 1 -print0 2>/dev/null | xargs -0 rm -rf || true

# Remove stale build artifacts
rm -rf "$APP_BUNDLE"
rm -f "$DMG_PATH"

# Build release binary
echo "Building release binary..."
cd "$APP_DIR"
swift build -c release

# Assemble app bundle
echo "Assembling app bundle..."
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy executable
cp "$APP_DIR/.build/release/TokenWatch" "$APP_BUNDLE/Contents/MacOS/TokenWatch"
chmod +x "$APP_BUNDLE/Contents/MacOS/TokenWatch"

# Copy and stamp Info.plist
cp "$APP_DIR/Sources/TokenWatch/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString $VERSION" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Add CFBundleShortVersionString string $VERSION" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set CFBundleVersion $VERSION" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Add CFBundleVersion string $VERSION" "$APP_BUNDLE/Contents/Info.plist"

# Copy icon if exists
if [[ -f "$APP_DIR/Resources/TokenWatch.icns" ]]; then
    cp "$APP_DIR/Resources/TokenWatch.icns" "$APP_BUNDLE/Contents/Resources/TokenWatch.icns"
fi

# Codesign
if [[ -n "$SIGN_IDENTITY" ]]; then
    echo "Codesigning with identity: $SIGN_IDENTITY"
    codesign --sign "$SIGN_IDENTITY" --force --deep --options runtime "$APP_BUNDLE"

    # Timestamp
    echo "Adding timestamp..."
    codesign --timestamp --sign "$SIGN_IDENTITY" "$APP_BUNDLE"

    # Verify strictly
    echo "Verifying signature..."
    codesign --verify --strict --deep "$APP_BUNDLE"
    spctl -a -vv "$APP_BUNDLE"
else
    echo "Ad-hoc signing..."
    codesign --sign - --force --deep "$APP_BUNDLE"
fi

# Create DMG staging
STAGING_DIR=$(mktemp -d)
trap "rm -rf '$STAGING_DIR'" EXIT

echo "Creating DMG..."
cp -R "$APP_BUNDLE" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

# Create UDZO DMG
hdiutil create -volname "TokenWatch" -srcfolder "$STAGING_DIR" -ov -format UDZO "$DMG_PATH"

echo "Built: $APP_BUNDLE"
echo "Built: $DMG_PATH"

# Notarize if profile provided
if [[ -n "$NOTARIZE_PROFILE" ]]; then
    echo "Notarizing DMG with profile: $NOTARIZE_PROFILE"
    xcrun notarytool submit "$DMG_PATH" --wait --profile "$NOTARIZE_PROFILE"
    echo "Stapling notarization..."
    xcrun stapler staple "$DMG_PATH"
    echo "Notarization complete"
fi

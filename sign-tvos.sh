#!/bin/bash

set -euo pipefail

# Sign an unsigned Moonfin tvOS Runner.app for installation on a
# personally registered Apple TV using an Apple Development certificate.
#
# Expected layout:
#   ./junk/Runner.app
#
# The script does NOT build the project.
# if the build isn't provisioned, run:
# open tvos/Runner.xcworkspace
# in the Runner TARGETS, select:
#   Team: -> <NAME> (Personal Team)
#   Bundle Identifier: org.moonfin.app -> <the name in the github secrets> (com.local-build.app)
#   App Groups: group.org.moonfin.app -> <the group name from github secrets> (group.com.local-build.app)
#     Create a new one if necessary
# in the MoonfinTopShelf TARGETS,
#   Team: -> <NAME> (Personal Team)
#   Bundle Identifier: org.moonfin.app.topshelf -> <the name in the github secrets> (com.local-build.app)
#   App Groups: group.org.moonfin.app -> <the group name from github secrets> (group.com.local-build.app)
#     Create a new one if necessary
# NOW the provisions exist on your mac -- revert any changes in the project area

PROFILE_DIR="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENV_FILE="$SCRIPT_DIR/build-env.sh"

if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: build-env.sh was not found:"
    echo "  $ENV_FILE"
    exit 1
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

required_vars=(
    TVOS_DEVELOPMENT_TEAM
    TVOS_MAIN_BUNDLE_ID
    TVOS_TOPSHELF_BUNDLE_ID
    TVOS_APP_GROUP
    TVOS_DEVICE_NAME
)

for var in "${required_vars[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        echo "ERROR: Required environment variable is not set:"
        echo "  $var"
        exit 1
    fi
done

MAIN_BUNDLE_ID="$TVOS_MAIN_BUNDLE_ID"
TOPSHELF_BUNDLE_ID="$TVOS_TOPSHELF_BUNDLE_ID"

APP="$SCRIPT_DIR/junk/Runner.app"

if [[ -n "${TVOS_DISPLAY_NAME:-}" ]]; then
    echo "=== Customizing .app ==="
    echo
    /usr/libexec/PlistBuddy \
        -c "Set :CFBundleDisplayName $TVOS_DISPLAY_NAME" \
        "$APP/Info.plist"
    echo "Done."
    echo
fi

echo "=== Moonfin tvOS signing ==="
echo

# ---------------------------------------------------------------------------
# Check prerequisites
# ---------------------------------------------------------------------------

if [[ ! -d "$APP" ]]; then
    echo "ERROR: App not found:"
    echo "  $APP"
    echo
    echo "Place Runner.app in the junk directory and try again."
    exit 1
fi

if [[ ! -d "$PROFILE_DIR" ]]; then
    echo "ERROR: Xcode provisioning profile directory not found:"
    echo "  $PROFILE_DIR"
    exit 1
fi

command -v codesign >/dev/null || {
    echo "ERROR: codesign not found."
    exit 1
}

command -v security >/dev/null || {
    echo "ERROR: security command not found."
    exit 1
}

# ---------------------------------------------------------------------------
# Verify bundle identifiers before modifying anything
# ---------------------------------------------------------------------------

echo "Checking bundle identifiers..."

ACTUAL_MAIN_ID=$(
    /usr/libexec/PlistBuddy \
        -c "Print :CFBundleIdentifier" \
        "$APP/Info.plist"
)

ACTUAL_TOPSHELF_ID=$(
    /usr/libexec/PlistBuddy \
        -c "Print :CFBundleIdentifier" \
        "$APP/PlugIns/MoonfinTopShelf.appex/Info.plist"
)

if [[ "$ACTUAL_MAIN_ID" != "$MAIN_BUNDLE_ID" ]]; then
    echo "ERROR: Unexpected main bundle identifier:"
    echo "  Found:    $ACTUAL_MAIN_ID"
    echo "  Expected: $MAIN_BUNDLE_ID"
    exit 1
fi

if [[ "$ACTUAL_TOPSHELF_ID" != "$TOPSHELF_BUNDLE_ID" ]]; then
    echo "ERROR: Unexpected Top Shelf bundle identifier:"
    echo "  Found:    $ACTUAL_TOPSHELF_ID"
    echo "  Expected: $TOPSHELF_BUNDLE_ID"
    exit 1
fi

echo "  Main:     $ACTUAL_MAIN_ID"
echo "  Top Shelf: $ACTUAL_TOPSHELF_ID"
echo

# ---------------------------------------------------------------------------
# Find provisioning profiles by inspecting their application identifiers.
# This avoids depending on random UUID filenames.
# ---------------------------------------------------------------------------

echo "Locating provisioning profiles..."

MAIN_PROFILE=""
TOPSHELF_PROFILE=""

for PROFILE in "$PROFILE_DIR"/*.mobileprovision; do
    [[ -f "$PROFILE" ]] || continue

    TMP_PLIST="$(mktemp)"

    if security cms -D -i "$PROFILE" -o "$TMP_PLIST" 2>/dev/null; then
        PROFILE_APP_ID=$(
            /usr/libexec/PlistBuddy \
                -c "Print :Entitlements:application-identifier" \
                "$TMP_PLIST" 2>/dev/null || true
        )

        case "$PROFILE_APP_ID" in
            *."$MAIN_BUNDLE_ID")
                MAIN_PROFILE="$PROFILE"
                ;;
            *."$TOPSHELF_BUNDLE_ID")
                TOPSHELF_PROFILE="$PROFILE"
                ;;
        esac
    fi

    rm -f "$TMP_PLIST"
done

if [[ -z "$MAIN_PROFILE" ]]; then
    echo "ERROR: Could not find a provisioning profile for:"
    echo "  $MAIN_BUNDLE_ID"
    exit 1
fi

if [[ -z "$TOPSHELF_PROFILE" ]]; then
    echo "ERROR: Could not find a provisioning profile for:"
    echo "  $TOPSHELF_BUNDLE_ID"
    exit 1
fi

echo "  Main profile:"
echo "    $MAIN_PROFILE"
echo "  Top Shelf profile:"
echo "    $TOPSHELF_PROFILE"
echo

# ---------------------------------------------------------------------------
# Find Apple Development signing identity.
#
# Use the certificate SHA-1 hash rather than the human-readable certificate
# name. This avoids shell/parsing problems with names containing email
# addresses, parentheses, etc.
# ---------------------------------------------------------------------------

echo "Locating Apple Development signing identity..."

IDENTITY_LINE="$(
    security find-identity -v -p codesigning 2>/dev/null |
    grep 'Apple Development:' |
    head -1
)"

if [[ -z "$IDENTITY_LINE" ]]; then
    echo "ERROR: No Apple Development signing certificate found."
    echo
    echo "Available signing identities:"
    security find-identity -v -p codesigning
    exit 1
fi

IDENTITY_HASH="$(printf '%s\n' "$IDENTITY_LINE" | awk '{print $2}')"

if [[ -z "$IDENTITY_HASH" ]]; then
    echo "ERROR: Could not extract signing identity hash."
    echo
    echo "Identity line was:"
    echo "$IDENTITY_LINE"
    exit 1
fi

echo "  Identity:"
echo "    $IDENTITY_LINE"
echo "  Hash:"
echo "    $IDENTITY_HASH"
echo

# ---------------------------------------------------------------------------
# Create unsigned backup if one doesn't already exist.
# ---------------------------------------------------------------------------

BACKUP="$SCRIPT_DIR/junk/Runner.app.unsigned"

if [[ -e "$BACKUP" ]]; then
    echo "Unsigned backup already exists:"
    echo "  $BACKUP"
    echo "  Leaving it untouched."
else
    echo "Creating unsigned backup:"
    echo "  $BACKUP"
    cp -R "$APP" "$BACKUP"
fi

echo

# ---------------------------------------------------------------------------
# Extract provisioning-profile entitlements.
# ---------------------------------------------------------------------------

MAIN_PROFILE_PLIST="$(mktemp)"
TOPSHELF_PROFILE_PLIST="$(mktemp)"
MAIN_ENTITLEMENTS="$(mktemp)"
TOPSHELF_ENTITLEMENTS="$(mktemp)"

cleanup() {
    rm -f \
        "$MAIN_PROFILE_PLIST" \
        "$TOPSHELF_PROFILE_PLIST" \
        "$MAIN_ENTITLEMENTS" \
        "$TOPSHELF_ENTITLEMENTS"
}
trap cleanup EXIT

echo "Extracting provisioning profile entitlements..."

security cms -D \
    -i "$MAIN_PROFILE" \
    -o "$MAIN_PROFILE_PLIST"

security cms -D \
    -i "$TOPSHELF_PROFILE" \
    -o "$TOPSHELF_PROFILE_PLIST"

plutil -extract Entitlements xml1 \
    -o "$MAIN_ENTITLEMENTS" \
    "$MAIN_PROFILE_PLIST"

plutil -extract Entitlements xml1 \
    -o "$TOPSHELF_ENTITLEMENTS" \
    "$TOPSHELF_PROFILE_PLIST"

echo "  Done."
echo

# ---------------------------------------------------------------------------
# Embed provisioning profiles.
# ---------------------------------------------------------------------------

echo "Embedding provisioning profiles..."

cp "$MAIN_PROFILE" \
    "$APP/embedded.mobileprovision"

cp "$TOPSHELF_PROFILE" \
    "$APP/PlugIns/MoonfinTopShelf.appex/embedded.mobileprovision"

echo "  Done."
echo

# ---------------------------------------------------------------------------
# Sign embedded frameworks.
#
# Frameworks are signed without application entitlements.
# ---------------------------------------------------------------------------

echo "Signing embedded frameworks..."

FRAMEWORK_COUNT=0

while IFS= read -r -d '' FRAMEWORK; do
    echo "  Signing $(basename "$FRAMEWORK")"

    codesign \
        --force \
        --sign "$IDENTITY_HASH" \
        --timestamp=none \
        "$FRAMEWORK"

    FRAMEWORK_COUNT=$((FRAMEWORK_COUNT + 1))
done < <(
    find "$APP/Frameworks" \
        -type d \
        -name "*.framework" \
        -print0
)

echo "  Signed $FRAMEWORK_COUNT frameworks."
echo

# ---------------------------------------------------------------------------
# Sign Top Shelf extension.
#
# The extension must be signed before the containing application.
# ---------------------------------------------------------------------------

echo "Signing MoonfinTopShelf.appex..."

codesign \
    --force \
    --sign "$IDENTITY_HASH" \
    --entitlements "$TOPSHELF_ENTITLEMENTS" \
    --timestamp=none \
    "$APP/PlugIns/MoonfinTopShelf.appex"

echo "  Done."
echo

# ---------------------------------------------------------------------------
# Sign main application last.
# ---------------------------------------------------------------------------

echo "Signing Runner.app..."

codesign \
    --force \
    --sign "$IDENTITY_HASH" \
    --entitlements "$MAIN_ENTITLEMENTS" \
    --timestamp=none \
    "$APP"

echo "  Done."
echo

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------

echo "=== Verification ==="
echo

echo "Main application:"
codesign -dv "$APP" 2>&1 |
    grep -E 'Identifier=|TeamIdentifier=|Signature size=|Signed Time=' || true
echo

echo "Top Shelf:"
codesign -dv "$APP/PlugIns/MoonfinTopShelf.appex" 2>&1 |
    grep -E 'Identifier=|TeamIdentifier=|Signature size=|Signed Time=' || true
echo

echo "Deep signature verification:"
codesign \
    --verify \
    --deep \
    --strict \
    --verbose=4 \
    "$APP"

echo

echo "Main app entitlements:"
codesign -d --entitlements :- "$APP" 2>&1 |
    sed -n '/<dict>/,/<\/dict>/p'

echo

echo "Embedded provisioning profiles:"
find "$APP" -name embedded.mobileprovision -print

echo
echo "=== Installing to  ${TVOS_DEVICE_NAME} ==="
echo
xcrun devicectl device install app --device "${TVOS_DEVICE_NAME}" ./junk/Runner.app
echo "Done."
echo

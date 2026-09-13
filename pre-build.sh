#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Moonfin tvOS pre-build ==="
echo

# ---------------------------------------------------------------------------
# Load build configuration
# ---------------------------------------------------------------------------

: "${TVOS_DEVELOPMENT_TEAM:?TVOS_DEVELOPMENT_TEAM is not set}"
: "${TVOS_MAIN_BUNDLE_ID:?TVOS_MAIN_BUNDLE_ID is not set}"
: "${TVOS_TOPSHELF_BUNDLE_ID:?TVOS_TOPSHELF_BUNDLE_ID is not set}"
: "${TVOS_APP_GROUP:?TVOS_APP_GROUP is not set}"


# ---------------------------------------------------------------------------
# Validate configuration
# ---------------------------------------------------------------------------

required_vars=(
    TVOS_DEVELOPMENT_TEAM
    TVOS_MAIN_BUNDLE_ID
    TVOS_TOPSHELF_BUNDLE_ID
    TVOS_APP_GROUP
)

for var in "${required_vars[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        echo "ERROR: Required environment variable is not set:"
        echo "  $var"
        exit 1
    fi
done

echo "Configuration:"
echo "  Development Team: $TVOS_DEVELOPMENT_TEAM"
echo "  Main Bundle ID:   $TVOS_MAIN_BUNDLE_ID"
echo "  Top Shelf ID:     $TVOS_TOPSHELF_BUNDLE_ID"
echo "  App Group:        $TVOS_APP_GROUP"
echo

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

PBXPROJ="$SCRIPT_DIR/tvos/Runner.xcodeproj/project.pbxproj"
MAIN_ENTITLEMENTS="$SCRIPT_DIR/tvos/Runner/Runner.entitlements"
TOPSHELF_ENTITLEMENTS="$SCRIPT_DIR/tvos/MoonfinTopShelf/MoonfinTopShelf.entitlements"

for file in \
    "$PBXPROJ" \
    "$MAIN_ENTITLEMENTS" \
    "$TOPSHELF_ENTITLEMENTS"
do
    if [[ ! -f "$file" ]]; then
        echo "ERROR: Expected file not found:"
        echo "  $file"
        exit 1
    fi
done

# ---------------------------------------------------------------------------
# Update entitlements
# ---------------------------------------------------------------------------

echo "Updating entitlements..."

python3 - "$MAIN_ENTITLEMENTS" "$TOPSHELF_ENTITLEMENTS" "$TVOS_APP_GROUP" <<'PY'
import sys
from pathlib import Path

main_path = Path(sys.argv[1])
topshelf_path = Path(sys.argv[2])
app_group = sys.argv[3]

for path in (main_path, topshelf_path):
    text = path.read_text()

    # Replace the upstream app group with our configured one.
    text = text.replace(
        "group.org.moonfin.app",
        app_group,
    )

    path.write_text(text)

    print(f"  Updated {path}")
PY

# ---------------------------------------------------------------------------
# Update Xcode project
# ---------------------------------------------------------------------------

echo "Updating Xcode project..."

python3 - "$PBXPROJ" \
    "$TVOS_DEVELOPMENT_TEAM" \
    "$TVOS_MAIN_BUNDLE_ID" \
    "$TVOS_TOPSHELF_BUNDLE_ID" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
development_team = sys.argv[2]
main_bundle_id = sys.argv[3]
topshelf_bundle_id = sys.argv[4]

text = path.read_text()

# Bundle identifiers.
#
# Do the Top Shelf identifier first so the base replacement does not
# partially modify it.
text = text.replace(
    "org.moonfin.app.topshelf",
    topshelf_bundle_id,
)

text = text.replace(
    "org.moonfin.app",
    main_bundle_id,
)

# Development team.
#
# This replaces DEVELOPMENT_TEAM assignments in this project with the
# locally configured personal team.
import re

text = re.sub(
    r"(DEVELOPMENT_TEAM\s*=\s*)[A-Z0-9]+(;)",
    rf"\g<1>{development_team}\g<2>",
    text,
)

path.write_text(text)

print(f"  Updated {path}")
PY

echo
echo "=== tvOS pre-build complete ==="

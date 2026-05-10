#!/usr/bin/env bash
#
# personalize-signing.sh — rewrite DEVELOPMENT_TEAM, PRODUCT_BUNDLE_IDENTIFIER,
# and App Group across the project so a fork can be built with the operator's
# own Apple Developer Team / bundle prefix without hand-editing six files.
#
# Updates:
#   MeterBar.xcodeproj/project.pbxproj         DEVELOPMENT_TEAM (×6)
#                                              PRODUCT_BUNDLE_IDENTIFIER (app + .Widget)
#   MeterBar/MeterBar.entitlements             application-groups
#   MeterBar/App/MeterBar.entitlements         application-groups
#   MeterBarWidget/MeterBarWidget.entitlements application-groups
#   MeterBar/Services/SharedDataStore.swift    appGroupIdentifier + Darwin signal name
#   MeterBarCLI/Sources/MeterBarCLI.swift      forSecurityApplicationGroupIdentifier
#
# pbxproj rewriting is context-aware: each PRODUCT_BUNDLE_IDENTIFIER is set
# based on which target the surrounding XCBuildConfiguration belongs to
# (detected from the CODE_SIGN_ENTITLEMENTS line that precedes it alphabetically
# in the buildSettings dict), so the script *repairs* a swapped or otherwise
# malformed file rather than propagating the existing values.
#
set -euo pipefail

usage() {
    cat <<EOF
Usage: $0 --team TEAM_ID --bundle BUNDLE_ID [--group APP_GROUP]

Required:
  --team TEAM_ID         Apple Developer Team ID (10-char alphanumeric, e.g. 8R67VZMQ57).
                         Find yours under Xcode → Settings → Accounts → your team.
  --bundle BUNDLE_ID     Reverse-DNS bundle identifier for the main app
                         (e.g. com.example.meterbar). The widget extension
                         uses BUNDLE_ID.Widget automatically.

Optional:
  --group APP_GROUP      App Group identifier. Defaults to "group.\$BUNDLE_ID".
  -h, --help             Show this help.

Example:
  $0 --team 8R67VZMQ57 --bundle com.example.meterbar
EOF
}

TEAM=""
BUNDLE=""
GROUP=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --team)   TEAM="$2";   shift 2 ;;
        --bundle) BUNDLE="$2"; shift 2 ;;
        --group)  GROUP="$2";  shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
    esac
done

if [[ -z "$TEAM" || -z "$BUNDLE" ]]; then
    usage
    exit 1
fi

GROUP="${GROUP:-group.$BUNDLE}"
WIDGET_BUNDLE="${BUNDLE}.Widget"

# Resolve repo root (script lives in scripts/)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

PBXPROJ="MeterBar.xcodeproj/project.pbxproj"
APP_ENTITLEMENTS_1="MeterBar/MeterBar.entitlements"
APP_ENTITLEMENTS_2="MeterBar/App/MeterBar.entitlements"
WIDGET_ENTITLEMENT="MeterBarWidget/MeterBarWidget.entitlements"
SHARED_STORE="MeterBar/Services/SharedDataStore.swift"
CLI="MeterBarCLI/Sources/MeterBarCLI.swift"

for f in "$PBXPROJ" "$APP_ENTITLEMENTS_1" "$WIDGET_ENTITLEMENT" "$SHARED_STORE"; do
    if [[ ! -f "$f" ]]; then
        echo "Missing expected file: $f" >&2
        exit 1
    fi
done

# Detect current App Group from one of the entitlements files (single source of truth).
CURRENT_GROUP=$(grep -m1 "<string>group\." "$APP_ENTITLEMENTS_1" \
    | sed -E 's|.*<string>(group\.[^<]+)</string>.*|\1|' || true)

if [[ -z "$CURRENT_GROUP" ]]; then
    echo "Failed to detect current App Group identifier in $APP_ENTITLEMENTS_1" >&2
    exit 1
fi

echo "Personalizing signing"
echo "  Team:   → $TEAM"
echo "  Bundle: → $BUNDLE   (widget: $WIDGET_BUNDLE)"
echo "  Group:  $CURRENT_GROUP → $GROUP"

# ── pbxproj: context-aware rewrite ──────────────────────────────────────────
# Walk the file tracking which target the current XCBuildConfiguration belongs
# to (via the CODE_SIGN_ENTITLEMENTS line). When we encounter a
# PRODUCT_BUNDLE_IDENTIFIER, write the bundle for that target. DEVELOPMENT_TEAM
# is set unconditionally since all targets share the same team.
TMP="$(mktemp)"
awk -v bundle="$BUNDLE" -v widget_bundle="$WIDGET_BUNDLE" -v team="$TEAM" '
    /CODE_SIGN_ENTITLEMENTS = MeterBarWidget\// { target = "widget" }
    /CODE_SIGN_ENTITLEMENTS = MeterBar\//        { target = "app" }
    /PRODUCT_BUNDLE_IDENTIFIER = / {
        if (target == "widget") {
            sub(/PRODUCT_BUNDLE_IDENTIFIER = [^;]+;/, "PRODUCT_BUNDLE_IDENTIFIER = " widget_bundle ";")
        } else if (target == "app") {
            sub(/PRODUCT_BUNDLE_IDENTIFIER = [^;]+;/, "PRODUCT_BUNDLE_IDENTIFIER = " bundle ";")
        }
    }
    /DEVELOPMENT_TEAM = / {
        sub(/DEVELOPMENT_TEAM = [^;]+;/, "DEVELOPMENT_TEAM = " team ";")
    }
    { print }
' "$PBXPROJ" > "$TMP"
mv "$TMP" "$PBXPROJ"

# ── entitlements + source files: just App Group ─────────────────────────────
for f in "$APP_ENTITLEMENTS_1" "$APP_ENTITLEMENTS_2" "$WIDGET_ENTITLEMENT" "$SHARED_STORE" "$CLI"; do
    if [[ -f "$f" ]]; then
        sed -i '' "s|${CURRENT_GROUP}|${GROUP}|g" "$f"
    fi
done

echo "Personalization complete. Rebuilding with the new identity…"
exec "$SCRIPT_DIR/rebuild-and-reload.sh"
echo "Done!"

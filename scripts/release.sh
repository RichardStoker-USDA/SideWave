#!/bin/bash
# Build, sign, notarize, and package a SideWave release.
#
#   scripts/release.sh                  Release from a clean main branch.
#   scripts/release.sh --skip-notarize  Signed DMG without notarization, for testing.
#   scripts/release.sh --install PATH   Sign the app and install it at PATH, for testing.
#   scripts/release.sh --allow-dirty    Skip the clean-main check (testing only).
#
# Output goes to build/release/<version>-<build>/: the notarized SideWave.dmg
# and appcast-item.xml for scripts/publish-release.sh.
#
# Needs: Xcode at DEVELOPER_DIR, XcodeGen, create-dmg, a Developer ID
# Application certificate for TEAM_ID, a notarytool keychain profile named
# NOTARY_PROFILE, and Sparkle's sign_update in SPARKLE_BIN.
set -euo pipefail

TEAM_ID="${TEAM_ID:-54ZH296UH3}"
NOTARY_PROFILE="${NOTARY_PROFILE:-SideWave}"
SPARKLE_BIN="${SPARKLE_BIN:-$HOME/.sparkle-tools/bin}"
REPO="${REPO:-RichardStoker-USDA/SideWave}"
SITE="${SITE:-https://sidewave.dev}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

notarize=true
install_path=""
allow_dirty=false
while [ $# -gt 0 ]; do
    case "$1" in
        --skip-notarize) notarize=false ;;
        --install) install_path="${2:?--install needs an app path}"; shift ;;
        --allow-dirty) allow_dirty=true ;;
        -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

fail() { echo "release: $*" >&2; exit 1; }
step() { printf '\n== %s\n' "$*"; }

for tool in xcodegen create-dmg; do
    command -v "$tool" >/dev/null || fail "$tool is not installed."
done
[ -x "$SPARKLE_BIN/sign_update" ] || fail "Sparkle's sign_update was not found in $SPARKLE_BIN."
[ -d "$DEVELOPER_DIR" ] || fail "Xcode was not found at $DEVELOPER_DIR."

if [ -z "$install_path" ] && ! $allow_dirty; then
    [ "$(git branch --show-current)" = main ] || fail "Release from main, or pass --allow-dirty to test."
    [ -z "$(git status --porcelain)" ] || fail "The working tree has uncommitted changes."
fi

sign_id="$(security find-identity -v -p codesigning | awk -F'"' -v team="($TEAM_ID)" 'index($2, "Developer ID Application:") == 1 && index($2, team) {print $2; exit}')"
[ -n "$sign_id" ] || fail "No Developer ID Application certificate for team $TEAM_ID in the keychain."

version="$(awk -F'"' '/^    MARKETING_VERSION:/ {print $2; exit}' project.yml)"
build="$(awk -F'"' '/^    CURRENT_PROJECT_VERSION:/ {print $2; exit}' project.yml)"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$build" =~ ^[0-9]+$ ]] || fail "project.yml has no release version and build."
min_macos="$(awk -F'"' '/^    MACOSX_DEPLOYMENT_TARGET:/ {print $2; exit}' project.yml)"

# Use the folder's on-disk spelling. On a case-insensitive volume an existing Build/ is the same
# folder, and two spellings of one path break Clang's module cache.
mkdir -p "$ROOT/build"
build_dir="$(realpath "$ROOT/build")"
out="$build_dir/release/$version-$build"
rm -rf "$out"
mkdir -p "$out"
app="$out/SideWave.app"
git rev-parse HEAD > "$out/source-commit"
echo "SideWave $version ($build), signing as: $sign_id"

step "Building"
xcodegen generate --quiet
xcodebuild build \
    -project SideWave.xcodeproj -scheme SideWave -configuration Release \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$build_dir/DerivedData" \
    -clonedSourcePackagesDirPath "$build_dir/SourcePackages" \
    -skipMacroValidation \
    CODE_SIGNING_ALLOWED=NO \
    SYMROOT="$out/products" OBJROOT="$out/intermediates" \
    > "$out/build.log" 2>&1 || { tail -30 "$out/build.log"; fail "Build failed. Full log: $out/build.log"; }
ditto "$out/products/Release/SideWave.app" "$app"
ditto "$out/products/Release/SideWave.app.dSYM" "$out/SideWave.app.dSYM" 2>/dev/null || true

step "Signing"
sign() { codesign --force --options runtime --timestamp --sign "$sign_id" "$@"; }
sparkle="$app/Contents/Frameworks/Sparkle.framework/Versions/B"
# Inside out, in the order Sparkle documents. The downloader keeps its own
# sandbox entitlements.
sign "$sparkle/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$sparkle/XPCServices/Downloader.xpc"
sign "$sparkle/Autoupdate"
sign "$sparkle/Updater.app"
sign "$app/Contents/Frameworks/Sparkle.framework"
while IFS= read -r -d '' nested; do
    sign "$nested"
done < <(find "$app/Contents/Frameworks" -maxdepth 1 \( -name '*.framework' -o -name '*.dylib' \) ! -name 'Sparkle.framework' -print0)
sign --entitlements "$ROOT/SideWave.entitlements" "$app"
codesign --verify --deep --strict "$app"
python3 scripts/validate_release.py "$app" > "$out/validation.json"

if [ -n "$install_path" ]; then
    step "Installing at $install_path"
    # Ask the running copy to quit normally so it saves its state.
    swift -e 'import AppKit; NSRunningApplication.runningApplications(withBundleIdentifier: "com.sidewave.app").forEach { $0.terminate() }' 2>/dev/null || true
    for _ in $(seq 1 20); do pgrep -x SideWave >/dev/null || break; sleep 0.5; done
    pkill -x SideWave 2>/dev/null || true
    rm -rf "$install_path"
    ditto "$app" "$install_path"
    echo "Installed. Open it with: open \"$install_path\""
    exit 0
fi

notarize_file() {
    local file="$1" label="$2"
    xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > "$out/notary-$label.json"
    local status
    status="$(plutil -extract status raw -o - "$out/notary-$label.json" 2>/dev/null || echo unknown)"
    [ "$status" = Accepted ] || fail "Notarization of $label returned $status. See $out/notary-$label.json."
}

if $notarize; then
    step "Notarizing the app"
    ditto -c -k --keepParent "$app" "$out/SideWave-notarize.zip"
    notarize_file "$out/SideWave-notarize.zip" app
    xcrun stapler staple "$app" >/dev/null
    rm "$out/SideWave-notarize.zip"
fi

step "Packaging the disk image"
dmg="$out/SideWave.dmg"
create-dmg \
    --volname SideWave \
    --volicon "$ROOT/scripts/dmg/volume.icns" \
    --background "$ROOT/scripts/dmg/background.tiff" \
    --window-pos 200 120 --window-size 600 400 \
    --icon-size 104 --icon SideWave.app 170 190 --hide-extension SideWave.app \
    --app-drop-link 430 190 \
    --no-internet-enable \
    "$dmg" "$app" > "$out/dmg.log" 2>&1 || fail "create-dmg failed. Log: $out/dmg.log"
codesign --sign "$sign_id" --timestamp "$dmg"

if $notarize; then
    step "Notarizing the disk image"
    notarize_file "$dmg" dmg
    xcrun stapler staple "$dmg" >/dev/null
    spctl --assess --type open --context context:primary-signature "$dmg"
fi

step "Signing for Sparkle"
signature="$("$SPARKLE_BIN/sign_update" "$dmg")"
[[ "$signature" == *'sparkle:edSignature='* ]] || fail "sign_update did not return a signature."
cat > "$out/appcast-item.xml" <<EOF
    <item>
      <title>Version $version</title>
      <sparkle:releaseNotesLink>$SITE/release-notes/$version.html</sparkle:releaseNotesLink>
      <sparkle:version>$build</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$min_macos</sparkle:minimumSystemVersion>
      <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
      <link>https://github.com/$REPO/releases/tag/v$version</link>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <enclosure url="https://github.com/$REPO/releases/download/v$version/SideWave.dmg" $signature type="application/octet-stream" />
    </item>
EOF

step "Done"
shasum -a 256 "$dmg" | tee "$out/SideWave.dmg.sha256"
echo "DMG:     $dmg"
echo "Appcast: $out/appcast-item.xml"
$notarize || echo "Not notarized. Don't publish this build."

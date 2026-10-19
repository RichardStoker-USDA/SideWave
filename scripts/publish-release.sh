#!/bin/bash
# Publish a release that scripts/release.sh built.
#
#   scripts/publish-release.sh         Create the GitHub release with SideWave.dmg, add the build
#                                      to the appcast, write the release notes page from
#                                      CHANGELOG.md, and rebuild the site into docs/.
#   scripts/publish-release.sh --push  Also commit those site changes and push main, which
#                                      publishes the appcast to sidewave.dev.
#
# The GitHub release goes up before the appcast changes, so the feed never points at a missing
# download. Run it from a clean main branch.
set -euo pipefail

REPO="${REPO:-RichardStoker-USDA/SideWave}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

push=false
case "${1:-}" in
    --push) push=true ;;
    "") ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
esac

fail() { echo "publish: $*" >&2; exit 1; }
step() { printf '\n== %s\n' "$*"; }

version="$(awk -F'"' '/^    MARKETING_VERSION:/ {print $2; exit}' project.yml)"
build="$(awk -F'"' '/^    CURRENT_PROJECT_VERSION:/ {print $2; exit}' project.yml)"
out="$ROOT/build/release/$version-$build"
dmg="$out/SideWave.dmg"
item="$out/appcast-item.xml"
[ -f "$dmg" ] && [ -f "$item" ] && [ -f "$out/source-commit" ] || fail "No release output in $out. Run scripts/release.sh first."
[ ! -e "$out/testing-build" ] || fail "$out is a testing build (--allow-dirty, --skip-notarize, or --install). Build again from a clean main."
[ "$(git branch --show-current)" = main ] || fail "Publish from main."
[ -z "$(git status --porcelain)" ] || fail "The working tree has changes."
xcrun stapler validate "$dmg" >/dev/null || fail "SideWave.dmg isn't notarized."
gh auth status >/dev/null 2>&1 || fail "gh isn't signed in."

notes="$out/release-notes.md"
python3 - "$version" "$notes" "site/public/release-notes/$version.html" <<'PY'
import html, re, sys
from pathlib import Path

version, notes_md, notes_html = sys.argv[1:4]
text = Path("CHANGELOG.md").read_text()
match = re.search(rf"^## {re.escape(version)} .*?$\n(.*?)(?=^## |\Z)", text, re.M | re.S)
if not match:
    sys.exit(f"publish: CHANGELOG.md has no section for {version}.")
body = match.group(1).strip()
Path(notes_md).write_text(body + "\n")

def inline(s):
    s = html.escape(s, quote=True)
    # Links to http(s) pages only; the escaping above keeps quotes out of the href.
    s = re.sub(r"\[([^\]]+)\]\((https?://[^)\s]+)\)", r'<a href="\2">\1</a>', s)
    return re.sub(r"`([^`]+)`", r"<code>\1</code>", s)

parts, items, para = [], [], []
def flush():
    if para:
        parts.append(f"<p>{inline(' '.join(para))}</p>")
        para.clear()
    if items:
        parts.append("<ul>" + "".join(f"<li>{inline(i)}</li>" for i in items) + "</ul>")
        items.clear()
for line in body.splitlines():
    if line.startswith("### "):
        flush()
        parts.append(f"<h3>{inline(line[4:])}</h3>")
    elif line.startswith("- "):
        if para:
            flush()
        items.append(line[2:])
    elif line.startswith("  ") and items:
        items[-1] += " " + line.strip()
    elif not line.strip():
        flush()
    else:
        para.append(line.strip())
flush()

Path(notes_html).parent.mkdir(parents=True, exist_ok=True)
Path(notes_html).write_text(f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>SideWave {version}</title>
<style>
  :root {{ color-scheme: light dark; }}
  body {{ font: 13px/1.5 -apple-system, BlinkMacSystemFont, sans-serif; margin: 16px 20px; color: #1d1d1f; }}
  h3 {{ font-size: 13px; margin: 16px 0 6px; }}
  ul {{ padding-left: 18px; margin: 0; }}
  li {{ margin-bottom: 4px; }}
  a {{ color: #0a62c9; }}
  @media (prefers-color-scheme: dark) {{ body {{ color: #e8e8ed; }} a {{ color: #6cb4ff; }} }}
</style>
</head>
<body>
{chr(10).join(parts)}
</body>
</html>
""")
PY

step "Creating GitHub release v$version"
local_digest="sha256:$(shasum -a 256 "$dmg" | awk '{print $1}')"
asset_digest() {
    gh api "repos/$REPO/releases/tags/v$version" --jq '.assets[] | select(.name == "SideWave.dmg") | .digest' 2>/dev/null
}
if gh release view "v$version" --repo "$REPO" >/dev/null 2>&1; then
    # A rerun after a later step failed. Go on only if the release holds this exact DMG.
    [ "$(asset_digest)" = "$local_digest" ] || fail "Release v$version already exists with a different SideWave.dmg."
    echo "Release v$version already has this SideWave.dmg."
else
    # Tag the commit the build came from; main may have moved on since.
    source_commit="$(cat "$out/source-commit")"
    git merge-base --is-ancestor "$source_commit" HEAD || fail "The build's commit isn't on main."
    git ls-remote --exit-code origin >/dev/null 2>&1 || fail "Can't reach origin."
    gh release create "v$version" "$dmg" --repo "$REPO" --target "$source_commit" \
        --title "SideWave $version" --notes-file "$notes"
fi
[ "$(asset_digest)" = "$local_digest" ] || fail "The uploaded SideWave.dmg doesn't match the local one."
# Sparkle downloads without signing in, so check the public link too. A private repository has
# none until it's made public.
if [ "$(gh api "repos/$REPO" --jq .private)" = false ]; then
    url="https://github.com/$REPO/releases/download/v$version/SideWave.dmg"
    code="$(curl -s -o /dev/null -w '%{http_code}' -L "$url")"
    [ "$code" = 200 ] || fail "The release download returned HTTP $code: $url"
else
    echo "The repository is private; the download link works once it's public."
fi

step "Adding $version to the appcast"
python3 - "$item" "$version" <<'PY'
import re, sys
from pathlib import Path

item = Path(sys.argv[1]).read_text().rstrip() + "\n"
version = sys.argv[2]
path = Path("site/public/appcast.xml")
xml = path.read_text()
items = re.findall(r"    <item>.*?</item>\n", xml, re.S)
kept = [i for i in items if f"<sparkle:shortVersionString>{version}<" not in i]
for i in items:
    xml = xml.replace(i, "")
xml = xml.replace("  </channel>", item + "".join(kept) + "  </channel>")
path.write_text(xml)
PY

step "Building the site"
(cd site && npm ci --no-audit --no-fund >/dev/null && npm run build >/dev/null)

if $push; then
    step "Publishing"
    git add site/public/appcast.xml "site/public/release-notes/$version.html" docs
    git commit -q -m "Publish $version"
    git push -q origin main
    echo "Pushed. When Pages has deployed, run:"
else
    echo "Site rebuilt. Review, commit, and push main, then run:"
fi
echo "  python3 scripts/validate_release.py \"$out/SideWave.app\" --distribution"

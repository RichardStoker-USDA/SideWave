#!/bin/bash
# Advance a release version without changing development build identities.
# Usage: ./scripts/bump-version.sh {build|patch|minor|major|set X.Y.Z}
set -euo pipefail

command -v xcodegen >/dev/null || { echo "Install XcodeGen before changing the version." >&2; exit 1; }
project_dir="$(cd -- "$(dirname -- "$0")/.." && pwd)"

python3 - "$project_dir" "$@" <<'PY'
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

root = Path(sys.argv[1])
path = root / "project.yml"
source = path.read_text()
arguments = sys.argv[2:] or ["build"]
action = arguments[0]
if action not in {"build", "patch", "minor", "major", "set"} or len(arguments) != (2 if action == "set" else 1):
    sys.exit("Usage: bump-version.sh {build|patch|minor|major|set X.Y.Z}")

def setting(name):
    values = re.findall(rf'^    {name}: "([^"\n]+)"$', source, re.MULTILINE)
    if len(values) != 1:
        sys.exit(f"Expected one base {name} in project.yml; no files changed.")
    return values[0]

version = setting("MARKETING_VERSION")
build = setting("CURRENT_PROJECT_VERSION")
if not re.fullmatch(r"\d+\.\d+\.\d+", version) or not build.isdigit():
    sys.exit("The base version must be X.Y.Z and its build must be an integer.")
major, minor, patch = map(int, version.split("."))
if action == "patch":
    version = f"{major}.{minor}.{patch + 1}"
elif action == "minor":
    version = f"{major}.{minor + 1}.0"
elif action == "major":
    version = f"{major + 1}.0.0"
elif action == "set":
    version = arguments[1]
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        sys.exit("Use a version in X.Y.Z format; no files changed.")

# Sparkle compares build numbers across marketing versions.
floor = int(build)
appcast = root / "site/public/appcast.xml"
if appcast.exists():
    published = ET.parse(appcast).findall(".//{http://www.andymatuschak.org/xml-namespaces/sparkle}version")
    for item in published:
        value = (item.text or "").strip()
        if not value.isdigit():
            sys.exit("The appcast contains a non-integer build. Resolve it before changing the version.")
        floor = max(floor, int(value))
next_build = floor + 1
updated = re.sub(r'^    MARKETING_VERSION: "[^"\n]+"$', f'    MARKETING_VERSION: "{version}"', source, flags=re.MULTILINE)
updated = re.sub(r'^    CURRENT_PROJECT_VERSION: "[^"\n]+"$', f'    CURRENT_PROJECT_VERSION: "{next_build}"', updated, flags=re.MULTILINE)
updated = re.sub(r'^(      MARKETING_VERSION: ")[^"\n]+(-dev(?:ag)?")$',
                 lambda match: match[1] + version + match[2], updated, flags=re.MULTILINE)
path.write_text(updated)
print(f"Updated v{version} (build {next_build}); development build numbers preserved.")
PY

cd "$project_dir"
xcodegen generate


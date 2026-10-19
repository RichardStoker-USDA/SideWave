#!/usr/bin/env python3
"""Build the app's third-party notices from Package.resolved and the package checkouts.

Run after resolving or updating Swift packages:

    python3 scripts/third_party_notices.py [--checkouts build/SourcePackages/checkouts]

scripts/third_party_notices.json names each package's license files and what SideWave uses it
for. The script copies those files verbatim from checkouts at the resolved revisions and writes
Sources/SideWave/Resources/ThirdPartyNotices.json, which Settings > About > Acknowledgments reads.
It also writes the ACKNOWLEDGMENTS list at the top of the repository. It stops if a resolved
package has no entry, or a checkout is at a different revision.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
CONFIG = ROOT / "scripts" / "third_party_notices.json"
OUTPUT = ROOT / "Sources" / "SideWave" / "Resources" / "ThirdPartyNotices.json"
LISTING = ROOT / "ACKNOWLEDGMENTS"
GROUPS = ["Speech models", "Language models", "Code"]


def checkout_revision(path):
    result = subprocess.run(["git", "-C", str(path), "rev-parse", "HEAD"], capture_output=True, text=True)
    return result.stdout.strip() if result.returncode == 0 else None


def find_checkout(checkouts, identity):
    for child in checkouts.iterdir():
        if child.is_dir() and child.name.lower() == identity:
            return child
    return None


def main():
    parser = argparse.ArgumentParser(description="Build the app's third-party notices.")
    parser.add_argument("--checkouts", type=Path, default=ROOT / "build" / "SourcePackages" / "checkouts")
    args = parser.parse_args()

    config = json.loads(CONFIG.read_text())
    pins = {pin["identity"]: pin for pin in json.loads((ROOT / "Package.resolved").read_text())["pins"]}
    packages = {package["identity"]: package for package in config["packages"]}

    problems = []
    for identity in sorted(pins):
        if identity not in packages and identity not in config["excluded"]:
            problems.append(f"{identity} is resolved but has no entry in {CONFIG.name}")
    for identity in packages:
        if identity not in pins:
            problems.append(f"{identity} has an entry but isn't in Package.resolved")

    texts = {}

    def add_text(path):
        # Keep the first line's indentation; Apache's title is centered with spaces.
        lines = path.read_text(encoding="utf-8").rstrip().splitlines()
        while lines and not lines[0].strip():
            lines.pop(0)
        content = "\n".join(line.rstrip() for line in lines) + "\n"
        key = hashlib.sha256(content.encode()).hexdigest()[:16]
        texts[key] = content
        return key

    entries = []
    for model in config["models"]:
        entries.append({**model, "version": None, "documents": []})
    # Packages carry no note; their license files are bundled.

    for package in config["packages"]:
        identity = package["identity"]
        pin = pins.get(identity)
        checkout = find_checkout(args.checkouts, identity)
        if not pin or not checkout:
            problems.append(f"{identity}: no checkout in {args.checkouts}")
            continue
        if checkout_revision(checkout) != pin["state"]["revision"]:
            problems.append(f"{identity}: checkout isn't at the resolved revision; resolve packages and build first")
            continue
        documents = []
        for item in [{"name": package["name"], "license": package["license"], "files": package["files"]}] + package.get("includes", []):
            for name in item["files"]:
                path = checkout / name
                if not path.is_file():
                    problems.append(f"{identity}: missing {name}")
                    continue
                documents.append({"title": item["name"], "license": item["license"], "file": name, "text": add_text(path)})
        entries.append({
            "id": identity,
            "group": "Code",
            "name": package["name"],
            "by": package["by"],
            "purpose": package["purpose"],
            "license": package["license"],
            "url": pin["location"].removesuffix(".git"),
            "licenseURL": None,
            "note": None,
            "version": pin["state"].get("version"),
            "documents": documents,
        })

    if problems:
        print("\n".join(problems), file=sys.stderr)
        return 1

    OUTPUT.write_text(json.dumps({"entries": entries, "texts": texts}, indent=1, ensure_ascii=False) + "\n")
    LISTING.write_text(listing(entries, config["packages"]))
    print(f"Wrote {OUTPUT.relative_to(ROOT)}: {len(entries)} entries, {len(texts)} distinct license texts.")
    print(f"Wrote {LISTING.relative_to(ROOT)}.")
    return 0


def listing(entries, packages):
    includes = {package["identity"]: package.get("includes", []) for package in packages}
    lines = [
        "ACKNOWLEDGMENTS",
        "",
        "SideWave uses the models and code below. Settings > About > Acknowledgments in the app",
        "shows every license and notice file in full. scripts/third_party_notices.py writes this list.",
    ]
    for group in GROUPS:
        lines += ["", "", group, "-" * len(group)]
        for entry in (e for e in entries if e["group"] == group):
            title = f"{entry['name']} {entry['version']}" if entry["version"] else entry["name"]
            license_line = f"License: {entry['license']}"
            if entry.get("licenseURL") and entry["licenseURL"] != entry["url"]:
                license_line += f" ({entry['licenseURL']})"
            lines += ["", title, f"  {entry['by']}", f"  {entry['purpose']}", f"  {license_line}", f"  {entry['url']}"]
            parts = [f"{item['name']} ({item['license']})" for item in includes.get(entry["id"], [])]
            if parts:
                lines.append(f"  Includes {', '.join(parts)}.")
    return "\n".join(lines) + "\n"


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Validate a local Developer ID build; optionally check public distribution gates."""
import argparse
import base64
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
from urllib.request import Request, urlopen
import xml.etree.ElementTree as ET


def run(label, *arguments):
    result = subprocess.run(arguments, capture_output=True, timeout=60)
    if result.returncode:
        raise ValueError(f"{label} failed (exit {result.returncode}).")
    return result.stdout, result.stderr


def require(condition, message):
    if not condition:
        raise ValueError(message)


TEAM_ID = "54ZH296UH3"


def inspect_code(path):
    run("Signature verification", "codesign", "--verify", "--deep", "--strict", str(path))
    _, metadata = run("Signature metadata", "codesign", "-d", "--verbose=4", str(path))
    metadata = metadata.decode()
    require("Authority=Developer ID Application:" in metadata, f"{path.name}: Developer ID Application signing is required.")
    require(f"TeamIdentifier={TEAM_ID}" in metadata, f"{path.name}: must be signed by team {TEAM_ID}.")
    flags = re.search(r"\bflags=0x([0-9a-fA-F]+)", metadata)
    require(flags and int(flags[1], 16) & 0x10000, f"{path.name}: Hardened runtime is required.")
    require("Timestamp=" in metadata, f"{path.name}: A secure signing timestamp is required.")
    raw, _ = run("Signed entitlements", "codesign", "-d", "--entitlements", "-", "--xml", str(path))
    entitlements = plistlib.loads(raw) if raw.strip() else {}
    require(not entitlements.get("com.apple.security.get-task-allow", False),
            f"{path.name}: Release code must not allow debugger attachment.")
    return entitlements


def verify_archive_signature(public_key, signature, archive):
    require(len(base64.b64decode(public_key, validate=True)) == 32,
            "A valid Sparkle public key is required.")
    require(len(base64.b64decode(signature, validate=True)) == 64,
            "A valid Sparkle download signature is required.")
    verify = '''import CryptoKit
import Foundation
let args = CommandLine.arguments
let key = try Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: args[1])!)
let signature = Data(base64Encoded: args[2])!
let archive = try Data(contentsOf: URL(fileURLWithPath: args[3]), options: .mappedIfSafe)
exit(key.isValidSignature(signature, for: archive) ? 0 : 1)
'''
    run("Sparkle download signature", "swift", "-e", verify, public_key, signature, str(archive))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--distribution", action="store_true",
                        help="Also require a notarization ticket and publicly reachable feed and assets.")
    args = parser.parse_args()
    app = args.app.resolve()
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    require(info.get("CFBundleIdentifier") == "com.sidewave.app", "Use the original SideWave Release app.")
    version = str(info.get("CFBundleVersion", ""))
    require(version.isdigit(), "The release build must be an integer.")
    require(info.get("LSMinimumSystemVersion") == "26.0", "The app must retain macOS 26 support.")
    require(info.get("LSApplicationCategoryType", "").startswith("public.app-category."),
            "The macOS application category is missing.")
    require(bool(info.get("NSMicrophoneUsageDescription")), "Microphone usage text is missing.")
    require(bool(info.get("NSAppleEventsUsageDescription")), "Automation usage text is missing.")
    require(info.get("SUSendProfileInfo") is False, "Sparkle system-profile reporting must remain disabled.")
    require(info.get("SUEnableAutomaticChecks") is not True,
            "Update checks must stay opt-in: Sparkle asks before the first automatic check.")
    require(len(base64.b64decode(info.get("SUPublicEDKey", ""), validate=True)) == 32,
            "A valid Sparkle public key is required.")
    feed = info.get("SUFeedURL", "")
    require(feed.startswith("https://"), "The update feed must use HTTPS.")
    executable = info.get("CFBundleExecutable", "")
    require(executable and Path(executable).name == executable, "The bundle executable name is invalid.")
    arch, _ = run("Architecture", "lipo", "-archs", str(app / "Contents/MacOS" / executable))
    require(arch.decode().strip() == "arm64", "The candidate must be an Apple Silicon build.")
    require(not list(app.rglob("*.xctest")), "Do not include test bundles in a release.")
    entitlements = inspect_code(app)
    require(entitlements.get("com.apple.security.device.audio-input") is True, "Audio-input entitlement is missing.")
    require(entitlements.get("com.apple.security.automation.apple-events") is True, "Automation entitlement is missing.")
    nested = {app / "Contents/Frameworks/Sparkle.framework/Autoupdate"}
    for pattern in ("*.app", "*.xpc", "*.framework"):
        nested.update(app.rglob(pattern))
    nested = {path.resolve() for path in nested}
    for path in sorted(nested):
        inspect_code(path)

    ns = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
    appcast = Path(__file__).resolve().parents[1] / "site/public/appcast.xml"
    if appcast.exists():
        for item in ET.parse(appcast).findall(".//" + ns + "version"):
            require((item.text or "").isdigit() and int(version) >= int(item.text),
                    "The candidate build is older than the checked-in appcast.")

    if args.distribution:
        run("Notarization ticket", "xcrun", "stapler", "validate", str(app))
        run("Gatekeeper assessment", "spctl", "--assess", "--type", "execute", str(app))
        with urlopen(Request(feed, headers={"User-Agent": "SideWave-release-validation"}), timeout=20) as response:
            require(response.geturl().startswith("https://"), "The feed redirected to an insecure URL.")
            content = response.read(1_048_577)
            require(len(content) <= 1_048_576, "The appcast exceeds 1 MB.")
            tree = ET.fromstring(content)
        entries = tree.findall("./channel/item")
        matching = [entry for entry in entries if entry.findtext(ns + "version") == version]
        require(bool(matching), "The public appcast does not contain this build.")
        for entry in matching:
            enclosure = entry.find("enclosure")
            require(enclosure is not None, "The release has no download enclosure.")
            url = enclosure.get("url", "")
            signature = enclosure.get(ns + "edSignature", "")
            require(url.startswith("https://") and len(base64.b64decode(signature, validate=True)) == 64,
                    "The release needs an HTTPS download with a Sparkle signature.")
            expected_size = int(enclosure.get("length", "0"))
            require(0 < expected_size <= 2_147_483_648, "The enclosure length is missing or exceeds 2 GB.")
            with tempfile.TemporaryDirectory(prefix="sidewave_release_validation_") as directory:
                archive = Path(directory) / "release_archive"
                received = 0
                with urlopen(url, timeout=30) as response, archive.open("wb") as output:
                    require(response.geturl().startswith("https://"), "The download redirected to an insecure URL.")
                    while chunk := response.read(1_048_576):
                        received += len(chunk)
                        require(received <= expected_size, "The download exceeds its declared length.")
                        output.write(chunk)
                require(received == expected_size, "The download length does not match the appcast.")
                verify_archive_signature(info["SUPublicEDKey"], signature, archive)

    print(json.dumps({"app": app.name, "version": info.get("CFBundleShortVersionString"), "build": version,
                      "developer_id_signature": "passed", "secure_timestamp": "passed",
                      "hardened_runtime": "passed", "debugger_entitlement": "absent",
                      "nested_signatures_checked": len(nested),
                      "distribution": "passed" if args.distribution else "not checked"}, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.TimeoutExpired, ET.ParseError) as error:
        print(f"Release validation failed: {error}", file=sys.stderr)
        sys.exit(1)

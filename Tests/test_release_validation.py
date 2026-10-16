"""Release checks reject unsafe signatures and modified Sparkle downloads."""
import base64
import importlib.util
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    "validate_release", Path(__file__).resolve().parents[1] / "scripts/validate_release.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseSigningTests(unittest.TestCase):
    metadata = b"Authority=Developer ID Application: Example\nflags=0x10000(runtime)\nTimestamp=Oct 14, 2026\n"

    def inspect(self, metadata=None, entitlements=None):
        signed = plistlib.dumps(entitlements or {})

        def run(label, *arguments):
            if label == "Signature metadata":
                return b"", self.metadata if metadata is None else metadata
            if label == "Signed entitlements":
                self.assertIn("--xml", arguments)
                return signed, b""
            return b"", b""

        with patch.object(release, "run", side_effect=run):
            return release.inspect_code(Path("SideWave.app"))

    def test_accepts_timestamped_hardened_signature_without_debugging(self):
        self.assertEqual(self.inspect(entitlements={"com.apple.security.device.audio-input": True}),
                         {"com.apple.security.device.audio-input": True})

    def test_rejects_development_entitlement(self):
        with self.assertRaisesRegex(ValueError, "debugger"):
            self.inspect(entitlements={"com.apple.security.get-task-allow": True})

    def test_rejects_missing_release_signing_requirements(self):
        for line in self.metadata.splitlines(keepends=True):
            with self.subTest(line=line):
                with self.assertRaises(ValueError):
                    self.inspect(metadata=self.metadata.replace(line, b""))


@unittest.skipUnless(sys.platform == "darwin", "Requires the macOS Swift CryptoKit toolchain")
class SparkleSignatureTests(unittest.TestCase):
    def test_real_signature_rejects_modified_archive_and_wrong_key(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "release.zip"
            archive.write_bytes(b"Signed release fixture")
            # The ephemeral signing key never leaves this process.
            fixture = '''import CryptoKit
import Foundation
let key = Curve25519.Signing.PrivateKey()
let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
print(key.publicKey.rawRepresentation.base64EncodedString())
print(try key.signature(for: data).base64EncodedString())
print(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString())
'''
            result = subprocess.run(["swift", "-e", fixture, str(archive)],
                                    capture_output=True, text=True, timeout=60, check=True)
            key, signature, wrong_key = result.stdout.splitlines()
            release.verify_archive_signature(key, signature, archive)
            with self.assertRaisesRegex(ValueError, "signature"):
                release.verify_archive_signature(wrong_key, signature, archive)
            archive.write_bytes(b"Modified release fixture")
            with self.assertRaisesRegex(ValueError, "signature"):
                release.verify_archive_signature(key, signature, archive)
            with self.assertRaisesRegex(ValueError, "signature"):
                release.verify_archive_signature(key, base64.b64encode(b"invalid").decode(), archive)


if __name__ == "__main__":
    unittest.main()

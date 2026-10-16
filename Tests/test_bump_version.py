"""Release numbering must remain newer than the appcast and preserve Dev identities."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class VersionBumpTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "scripts").mkdir()
        shutil.copyfile(Path(__file__).resolve().parents[1] / "scripts/bump-version.sh",
                        self.root / "scripts/bump-version.sh")
        self.project = self.root / "project.yml"
        self.project.write_text('''settings:
  base:
    MARKETING_VERSION: "0.2.1"
    CURRENT_PROJECT_VERSION: "9"
  configs:
    Debug:
      CURRENT_PROJECT_VERSION: "9999"
      MARKETING_VERSION: "0.2.1-dev"
    DebugAG:
      CURRENT_PROJECT_VERSION: "9999"
      MARKETING_VERSION: "0.2.1-devag"
''')
        public = self.root / "site/public"
        public.mkdir(parents=True)
        (public / "appcast.xml").write_text('''<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
<channel><item><sparkle:version>12</sparkle:version></item></channel></rss>''')
        binary = self.root / "bin"
        binary.mkdir()
        generator = binary / "xcodegen"
        generator.write_text('#!/bin/sh\ntouch generated_project\n')
        generator.chmod(0o755)
        self.env = dict(os.environ, PATH=str(binary) + os.pathsep + os.environ["PATH"])

    def run_bump(self, *args):
        return subprocess.run(["bash", str(self.root / "scripts/bump-version.sh"), *args],
                              env=self.env, capture_output=True, text=True)

    def test_build_advances_past_published_release_without_touching_dev_builds(self):
        result = self.run_bump("build")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('    CURRENT_PROJECT_VERSION: "13"', self.project.read_text())
        self.assertEqual(self.project.read_text().count('      CURRENT_PROJECT_VERSION: "9999"'), 2)
        self.assertTrue((self.root / "generated_project").exists())
        self.assertEqual(self.run_bump("build").returncode, 0)
        self.assertIn('    CURRENT_PROJECT_VERSION: "14"', self.project.read_text())

    def test_marketing_changes_never_reset_the_release_build(self):
        for arguments, expected in [(('patch',), '0.2.2'), (('minor',), '0.3.0'),
                                    (('major',), '1.0.0'), (('set', '2.4.6'), '2.4.6')]:
            with self.subTest(arguments=arguments):
                result = self.run_bump(*arguments)
                self.assertEqual(result.returncode, 0, result.stderr)
                text = self.project.read_text()
                self.assertIn(f'    MARKETING_VERSION: "{expected}"', text)
                self.assertIn(f'      MARKETING_VERSION: "{expected}-dev"', text)
                self.assertIn(f'      MARKETING_VERSION: "{expected}-devag"', text)
                self.assertNotIn('    CURRENT_PROJECT_VERSION: "1"', text)
                self.assertEqual(text.count('      CURRENT_PROJECT_VERSION: "9999"'), 2)

    def test_invalid_arguments_leave_project_unchanged(self):
        original = self.project.read_bytes()
        for arguments in [('set',), ('set', 'invalid'), ('patch', 'extra'), ('unknown',)]:
            with self.subTest(arguments=arguments):
                self.assertNotEqual(self.run_bump(*arguments).returncode, 0)
                self.assertEqual(self.project.read_bytes(), original)
        self.assertFalse((self.root / "generated_project").exists())


if __name__ == "__main__":
    unittest.main()

"""Exercise release failure recovery without building or publishing real assets."""
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest

SOURCE_ROOT = Path(__file__).resolve().parents[2]


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="VJDeck release tests ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        self.remote = self.root / "origin.git"
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.log = self.root / "commands.log"
        self.env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}",
                        TEST_LOG=str(self.log), TEST_PARTIAL_MARKER=str(self.root / "partial"))
        self.git("init", "--initial-branch=main")
        self.git("config", "user.email", "release-test@example.com")
        self.git("config", "user.name", "Release Test")
        self.git("config", "commit.gpgsign", "false")
        self.git("config", "tag.gpgsign", "false")
        subprocess.run(["git", "init", "--bare", str(self.remote)], check=True, capture_output=True)
        (self.repo / "scripts").mkdir()
        for name in ["release.sh", "build-dmg.sh"]:
            shutil.copy2(SOURCE_ROOT / "scripts" / name, self.repo / "scripts" / name)
        (self.repo / "Resources").mkdir()
        self.info = self.repo / "Resources/Info.plist"
        self.info.write_bytes(plistlib.dumps({"CFBundleShortVersionString": "1.5.4", "CFBundleVersion": "1.5.4"}))
        (self.repo / ".gitignore").write_text("build/\n")
        (self.repo / "CHANGELOG.md").write_text("# Changelog\n\n## [1.5.5] - 2026-10-09\n\nUpdate notes.\n")
        self.git("add", ".")
        self.git("commit", "-m", "Fixture")
        self.git("remote", "add", "origin", str(self.remote))
        self.git("push", "-u", "origin", "main")
        self.initial_head = self.git("rev-parse", "HEAD")
        self.stub("gh", r'''
printf 'gh %s\n' "$*" >> "$TEST_LOG"
case "$1 $2" in
  'auth status') exit 0 ;;
  'api repos/vjdeck/site') echo "${TEST_WRITABLE:-true}" ;;
  'release view') [ -f "$TEST_PARTIAL_MARKER" ] ;;
  'release create')
    if [ "${TEST_FAIL_PUBLISH:-0}" = 1 ]; then
      [ "${TEST_PARTIAL:-0}" != 1 ] || touch "$TEST_PARTIAL_MARKER"
      exit 1
    fi
    touch "$TEST_PARTIAL_MARKER" ;;
  *) exit 1 ;;
esac
''')
        self.stub("xcodebuild", r'''
printf 'xcodebuild %s\n' "$*" >> "$TEST_LOG"
[ "${TEST_FAIL_BUILD:-0}" != 1 ] || exit 2
while [ "$#" -gt 0 ]; do
  if [ "$1" = -derivedDataPath ]; then derived=$2; shift; fi
  shift
done
mkdir -p "$derived/Build/Products/Release/VJDeck.app/Contents"
cp Resources/Info.plist "$derived/Build/Products/Release/VJDeck.app/Contents/Info.plist"
''')
        self.stub("codesign", r'''printf 'codesign %s\n' "$*" >> "$TEST_LOG"''')
        self.stub("hdiutil", r'''
printf 'hdiutil %s\n' "$*" >> "$TEST_LOG"
for arg in "$@"; do case "$arg" in *.dmg) printf 'fixture dmg\n' > "$arg" ;; esac; done
''')

    def stub(self, name, script):
        path = self.bin / name
        path.write_text("#!/bin/bash\nset -eu\n" + script)
        path.chmod(0o755)

    def git(self, *args):
        return subprocess.run(["git", *args], cwd=self.repo, check=True,
                              capture_output=True, text=True).stdout.strip()

    def release(self, *args, **changes):
        return subprocess.run(["bash", "scripts/release.sh", *(args or ["patch"])],
                              cwd=self.repo, env=dict(self.env, **changes),
                              capture_output=True, text=True, timeout=20)

    def version(self):
        return plistlib.loads(self.info.read_bytes())["CFBundleShortVersionString"]

    def test_missing_changelog_stops_even_dry_run(self):
        (self.repo / "CHANGELOG.md").write_text("## [1.5.4]\nOld notes.\n")
        result = self.release("patch", "--dry-run")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("add a ## [1.5.5] section", result.stderr)
        self.assertEqual(self.version(), "1.5.4")
        self.assertFalse(self.log.exists())

    def test_empty_notes_are_rejected(self):
        (self.repo / "CHANGELOG.md").write_text("## [1.5.5]\n\n## [1.5.4]\nOld notes.\n")
        result = self.release("patch", "--dry-run")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must contain release notes", result.stderr)

    def test_dry_run_does_not_build_or_publish(self):
        result = self.release("patch", "--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Next version:    1.5.5", result.stdout)
        self.assertEqual(self.version(), "1.5.4")
        self.assertFalse(self.log.exists())

    def test_write_access_is_checked_before_version_change(self):
        result = self.release(TEST_WRITABLE="false")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("needs write access", result.stderr)
        self.assertEqual(self.version(), "1.5.4")
        self.assertEqual(self.git("rev-parse", "HEAD"), self.initial_head)
        self.assertNotIn("xcodebuild", self.log.read_text())

    def test_build_failure_restores_version_without_committing(self):
        result = self.release(TEST_FAIL_BUILD="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("version file was restored", result.stderr)
        self.assertEqual(self.version(), "1.5.4")
        self.assertEqual(self.git("rev-parse", "HEAD"), self.initial_head)
        self.assertEqual(self.git("status", "--porcelain"), "")

    def test_publish_failure_keeps_assets_and_prints_completion_commands(self):
        result = self.release(TEST_FAIL_PUBLISH="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("git push --atomic origin main v1.5.5", result.stderr)
        self.assertIn("gh release create v1.5.5", result.stderr)
        self.assertIn("--notes-file", result.stderr)
        self.assertEqual(self.version(), "1.5.5")
        self.assertEqual(self.git("rev-parse", "HEAD"), self.git("rev-parse", "origin/main"))
        self.assertTrue((self.repo / "build/release/VJDeck-1.5.5.zip").exists())
        self.assertTrue((self.repo / "build/release/VJDeck.dmg").exists())

    def test_partial_publish_prints_upload_and_notes_recovery(self):
        result = self.release(TEST_FAIL_PUBLISH="1", TEST_PARTIAL="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("gh release upload v1.5.5", result.stderr)
        self.assertIn("--clobber", result.stderr)
        self.assertIn("gh release edit v1.5.5", result.stderr)

    def test_push_failure_keeps_local_commit_and_prints_recovery(self):
        hook = self.remote / "hooks/pre-receive"
        hook.write_text("#!/bin/sh\nexit 1\n")
        hook.chmod(0o755)
        result = self.release()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.version(), "1.5.5")
        self.assertEqual(self.git("rev-parse", "origin/main"), self.initial_head)
        self.assertEqual(self.git("rev-parse", "v1.5.5^{}"), self.git("rev-parse", "HEAD"))
        self.assertIn("git push --atomic origin main v1.5.5", result.stderr)
        self.assertNotIn("gh release create", self.log.read_text())

    def test_success_uses_shared_build_and_matching_zip_and_notes(self):
        result = self.release()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Published https://github.com/vjdeck/site/releases/tag/v1.5.5", result.stdout)
        self.assertEqual(self.version(), "1.5.5")
        log = self.log.read_text()
        self.assertEqual(log.count("xcodebuild "), 1)
        self.assertEqual(log.count("hdiutil "), 1)
        self.assertIn("VJDeck-1.5.5.zip", log)
        self.assertEqual((self.repo / "build/release/notes-1.5.5.md").read_text().strip(), "Update notes.")
        extracted = self.root / "extracted"
        subprocess.run(["/usr/bin/ditto", "-x", "-k", str(self.repo / "build/release/VJDeck-1.5.5.zip"), str(extracted)], check=True)
        version = plistlib.loads((extracted / "VJDeck.app/Contents/Info.plist").read_bytes())["CFBundleShortVersionString"]
        self.assertEqual(version, "1.5.5")


if __name__ == "__main__":
    unittest.main(verbosity=2)

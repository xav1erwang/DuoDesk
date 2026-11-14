"""Scripts/build-duodesk-mac.sh's choice of signing identity, without a keychain or a build.

A CI runner has no Apple Development certificate, and `security find-identity` there prints
"0 valid identities found". That used to end the script under `set -o pipefail` before it
reached a single compiler line, with nothing on stderr to say why: every job in
.github/workflows failed on a green tree. The checks below stand in for `security` and
`swift` on PATH, so each case says what the script decided without compiling anything.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Scripts/build-duodesk-mac.sh"

IDENTITY = "0F7F2CB9D0775E039919B69D4A6E2CC9589F0F32"
NO_IDENTITIES = '#!/bin/bash\necho "  0 valid identities found"\nexit 0\n'
ONE_IDENTITY = (
    '#!/bin/bash\n'
    'printf \'  1) %s "Apple Development: someone@example.com (TEAMID1234)"\\n\'\n'
    'printf \'     1 valid identities found\\n\'\n' % IDENTITY
)
# The build stops at the compiler: the case is which identity the script chose on the way, and
# reaching this line at all is the regression's answer.
SWIFT_STUB = '#!/bin/bash\necho "swift-stub reached"\nexit 1\n'


class BuildSigningIdentityTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.bin = Path(self.directory.name) / "bin"
        self.bin.mkdir()
        (self.bin / "swift").write_text(SWIFT_STUB)
        (self.bin / "swift").chmod(0o755)

    def identity_stub(self, body):
        (self.bin / "security").write_text(body)
        (self.bin / "security").chmod(0o755)

    def run_build(self, *arguments, extra_env=None):
        environment = {key: value for key, value in os.environ.items() if not key.startswith("DUODESK_")}
        environment["PATH"] = f"{self.bin}:{environment['PATH']}"
        environment.update(extra_env or {})
        output = Path(self.directory.name) / "output"
        return subprocess.run(
            ["/bin/bash", str(SCRIPT), "--arch", "arm64", "--output", str(output), *arguments],
            capture_output=True, text=True, env=environment, cwd=ROOT,
        )

    def test_no_identity_builds_ad_hoc_instead_of_ending_silently(self):
        self.identity_stub(NO_IDENTITIES)
        result = self.run_build()
        self.assertIn("swift-stub reached", result.stdout,
                      f"the script never reached the build: stdout={result.stdout!r} stderr={result.stderr!r}")
        self.assertEqual(result.returncode, 1, "the stub compiler's own failure is the exit status")

    def test_the_apple_development_identity_is_chosen_when_there_is_one(self):
        self.identity_stub(ONE_IDENTITY)
        result = self.run_build()
        self.assertIn("swift-stub reached", result.stdout)
        self.assertNotIn("0 valid identities", result.stdout + result.stderr)

    def test_an_explicit_identity_is_never_second_guessed(self):
        self.identity_stub(NO_IDENTITIES)
        result = self.run_build(extra_env={"DUODESK_SIGN_IDENTITY": "Developer ID Application: Someone (TEAMID1234)"})
        self.assertIn("swift-stub reached", result.stdout)

    def test_release_without_credentials_says_so(self):
        self.identity_stub(NO_IDENTITIES)
        result = self.run_build("--release")
        self.assertEqual(result.returncode, 2)
        self.assertIn("--release requires DUODESK_SIGN_IDENTITY", result.stderr)
        self.assertNotIn("swift-stub reached", result.stdout)


if __name__ == "__main__":
    unittest.main()

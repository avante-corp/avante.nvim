"""Ensure CLI help and argument errors do not load service dependencies."""

import subprocess
import sys
import unittest
from pathlib import Path

ENTRY_POINT = Path(__file__).resolve().parents[1] / "src" / "main.py"


class CliTests(unittest.TestCase):
    """Exercise the CLI with site packages disabled."""

    def test_help_without_dependencies(self) -> None:
        """Help must work without importing any third-party packages."""
        result = subprocess.run(
            [sys.executable, "-S", str(ENTRY_POINT), "--help"],
            capture_output=True,
            text=True,
            check=False,
            timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")
        self.assertTrue(result.stdout.startswith("usage:"))
        self.assertIn("--embed-provider", result.stdout)

    def test_invalid_argument_without_dependencies(self) -> None:
        """Argument validation must happen before service imports."""
        result = subprocess.run(
            [sys.executable, "-S", str(ENTRY_POINT), "--port", "invalid"],
            capture_output=True,
            text=True,
            check=False,
            timeout=10,
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("invalid int value", result.stderr)
        self.assertNotIn("Traceback", result.stderr)


if __name__ == "__main__":
    unittest.main()

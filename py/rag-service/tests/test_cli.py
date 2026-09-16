"""Ensure CLI help and argument errors do not load service dependencies."""  # noqa: INP001

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
        self.assertEqual(result.returncode, 0, result.stderr)  # noqa: PT009
        self.assertEqual(result.stderr, "")  # noqa: PT009
        self.assertTrue(result.stdout.startswith("usage:"))  # noqa: PT009
        self.assertIn("--embed-provider", result.stdout)  # noqa: PT009

    def test_invalid_argument_without_dependencies(self) -> None:
        """Argument validation must happen before service imports."""
        result = subprocess.run(
            [sys.executable, "-S", str(ENTRY_POINT), "--port", "invalid"],
            capture_output=True,
            text=True,
            check=False,
            timeout=10,
        )
        self.assertEqual(result.returncode, 2)  # noqa: PT009
        self.assertIn("invalid int value", result.stderr)  # noqa: PT009
        self.assertNotIn("Traceback", result.stderr)  # noqa: PT009


if __name__ == "__main__":
    unittest.main()

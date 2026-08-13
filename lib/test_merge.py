import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from merge import merge

MERGE_PY = str(Path(__file__).resolve().parent / "merge.py")


class MergeTest(unittest.TestCase):
    def test_merges_objects_recursively(self):
        base = {"provider": {"scads": {"name": "SCADS", "options": {"baseURL": "a"}}}}
        overlay = {"provider": {"scads": {"options": {"baseURL": "b"}}}}
        self.assertEqual(
            merge(base, overlay),
            {"provider": {"scads": {"name": "SCADS", "options": {"baseURL": "b"}}}},
        )

    def test_replaces_arrays_wholesale(self):
        self.assertEqual(merge({"plugin": ["a", "b", "c"]}, {"plugin": ["d"]}), {"plugin": ["d"]})

    def test_replaces_scalars(self):
        self.assertEqual(merge({"model": "x"}, {"model": "y"}), {"model": "y"})

    def test_null_deletes_a_key(self):
        base = {"provider": {"local-a": {"name": "local-a"}, "scads": {"name": "scads"}}}
        overlay = {"provider": {"local-a": None}}
        self.assertEqual(merge(base, overlay), {"provider": {"scads": {"name": "scads"}}})

    def test_null_on_a_missing_key_is_not_an_error(self):
        self.assertEqual(merge({"a": 1}, {"b": None}), {"a": 1})

    def test_adds_keys_the_base_lacks(self):
        self.assertEqual(merge({"a": 1}, {"b": 2}), {"a": 1, "b": 2})

    def test_does_not_mutate_the_base(self):
        base = {"provider": {"scads": {"name": "SCADS"}}}
        merge(base, {"provider": {"scads": {"name": "other"}}})
        self.assertEqual(base["provider"]["scads"]["name"], "SCADS")

    def test_object_replaces_a_scalar(self):
        self.assertEqual(merge({"a": 1}, {"a": {"b": 2}}), {"a": {"b": 2}})


class CliTest(unittest.TestCase):
    def run_cli(self, base_text, overlay_text):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp) / "base.json"
            overlay = Path(tmp) / "overlay.json"
            base.write_text(base_text)
            overlay.write_text(overlay_text)
            return subprocess.run(
                [sys.executable, MERGE_PY, str(base), str(overlay)],
                capture_output=True,
                text=True,
            )

    def test_prints_merged_json(self):
        result = self.run_cli('{"model": "x"}', '{"model": "y"}')
        self.assertEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout), {"model": "y"})

    def test_rejects_an_invalid_overlay(self):
        result = self.run_cli('{"model": "x"}', "{not json")
        self.assertEqual(result.returncode, 1)
        self.assertIn("merge.py:", result.stderr)

    def test_rejects_a_missing_file(self):
        result = subprocess.run(
            [sys.executable, MERGE_PY, "/nonexistent/a.json", "/nonexistent/b.json"],
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 1)


if __name__ == "__main__":
    unittest.main()

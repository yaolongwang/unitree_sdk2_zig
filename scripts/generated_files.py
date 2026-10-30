#!/usr/bin/env python3
"""比较和写入生成文件，并提供格式兼容性自检。

Markdown 比较忽略表格填充空格和分隔线长度；JSON 比较保留数据类型与数组顺序。
内容相同的文件保留现有排版。--self-test 执行自检，模块导入不运行自检。
"""

from __future__ import annotations

import json
import re
from pathlib import Path


def _cells(line: str) -> list[str] | None:
    line = line.rstrip(" \t")
    if not line.startswith("|") or not line.endswith("|"):
        return None
    return [cell.strip(" \t") for cell in re.split(r"(?<!\\)\|", line[1:-1])]


def _markdown(source: str) -> list[str]:
    """Remove table padding. Keep cell text and column alignment."""
    lines = source.splitlines()
    index = 0
    fence = None
    while index < len(lines):
        marker = re.match(r"^ {0,3}(`{3,}|~{3,})(.*)$", lines[index])
        if marker:
            if fence is None:
                fence = marker[1]
            elif (
                marker[1][0] == fence[0]
                and len(marker[1]) >= len(fence)
                and not marker[2].strip()
            ):
                fence = None
        elif fence is None and index + 1 < len(lines):
            header = _cells(lines[index])
            separator = _cells(lines[index + 1])
            if (
                header
                and separator
                and len(header) == len(separator)
                and all(re.fullmatch(r":?-+:?", cell) for cell in separator)
            ):
                lines[index] = "|" + "|".join(header) + "|"
                lines[index + 1] = (
                    "|" + "|".join(re.sub(r"-+", "-", cell) for cell in separator) + "|"
                )
                index += 2
                while index < len(lines):
                    cells = _cells(lines[index])
                    if cells is None:
                        break
                    lines[index] = "|" + "|".join(cells) + "|"
                    index += 1
                continue
        index += 1
    return lines


def _json_object(pairs: list[tuple]) -> dict:
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"Duplicate JSON key: {key}")
        result[key] = value
    return result


def _json(source: str) -> str:
    value = json.loads(source, object_pairs_hook=_json_object)
    # Canonical JSON keeps booleans distinct from numbers and preserves array order.
    return json.dumps(value, sort_keys=True, ensure_ascii=False, allow_nan=False)


def matches(path: Path, expected: str, *, kind: str = "text") -> bool:
    """Return false for a missing, invalid, or changed file."""
    try:
        actual = path.read_text(encoding="utf-8")
    except (FileNotFoundError, UnicodeDecodeError):
        return False
    if kind == "markdown":
        return _markdown(actual) == _markdown(expected)
    if kind == "json":
        try:
            return _json(actual) == _json(expected)
        except ValueError:
            return False
    return actual == expected


def check_or_write(
    path: Path, expected: str, *, check: bool, kind: str = "text"
) -> bool:
    """Keep matching files. Return false if check mode finds a difference."""
    if matches(path, expected, kind=kind):
        return True
    if check:
        return False
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(expected, encoding="utf-8", newline="\n")
    return True


def self_test() -> int:
    import tempfile
    import unittest

    table = "# API\n\n| Method | Count |\n|---|---:|\n| `move(vx: f32)` | 1 |\n"
    formatted_table = (
        "# API\n\n| Method          | Count |\n"
        "| --------------- | ----: |\n| `move(vx: f32)`  |     1 |\n"
    )
    temporary_root = Path(__file__).resolve().parents[1] / "tmp"

    class GeneratedFilesTest(unittest.TestCase):
        def setUp(self):
            directory = tempfile.TemporaryDirectory(dir=temporary_root)
            self.addCleanup(directory.cleanup)
            self.path = Path(directory.name) / "output"

        def check_match(self, actual, expected, kind, result=True):
            self.path.write_text(actual, encoding="utf-8", newline="")
            self.assertEqual(matches(self.path, expected, kind=kind), result)

        def test_markdown_table_layout(self):
            self.check_match(formatted_table.replace("\n", "\r\n"), table, "markdown")
            escaped = table.replace("`move(vx: f32)`", r"`left\|right`")
            formatted = formatted_table.replace("`move(vx: f32)`", r"`left\|right`")
            self.check_match(formatted, escaped, "markdown")

        def test_markdown_content_changes(self):
            for old, new in [
                ("f32", "f64"),
                ("move", "stop"),
                ("|     1 |", "|     2 |"),
                ("----:", ":----"),
                ("# API", "# Commands"),
                ("vx: f32", "vx:  f32"),
                ("Count |", "Count | Extra |"),
            ]:
                with self.subTest(change=(old, new)):
                    self.check_match(
                        formatted_table.replace(old, new), table, "markdown", False
                    )

        def test_markdown_code_and_non_table_text_are_exact(self):
            for fence in ["```", "~~~~"]:
                self.check_match(
                    f"{fence}\n{formatted_table}{fence}\n",
                    f"{fence}\n{table}{fence}\n",
                    "markdown",
                    False,
                )
            self.check_match("| plain  text |\n", "| plain text |\n", "markdown", False)

        def test_json_layout_key_order_and_escapes(self):
            expected = '{"count": 1, "names": ["左", "right"]}'
            formatted = json.dumps({"names": ["左", "right"], "count": 1}, indent=4)
            self.check_match(formatted, expected, "json")

        def test_json_data_changes(self):
            expected = '{"count": 1, "names": ["left", "right"]}'
            for actual in [
                '{"count": 2, "names": ["left", "right"]}',
                '{"count": true, "names": ["left", "right"]}',
                '{"count": "1", "names": ["left", "right"]}',
                '{"count": 1, "names": ["right", "left"]}',
                '{"count": 1, "names": ["left ", "right"]}',
                '{"count": 1}',
                '{"count": 1, "names": ["left", "right"], "extra": 0}',
            ]:
                with self.subTest(actual=actual):
                    self.check_match(actual, expected, "json", False)

        def test_invalid_json_is_stale(self):
            for actual in ["{", '{"count": 2, "count": 1}', '{"count": NaN}']:
                with self.subTest(actual=actual):
                    self.check_match(actual, '{"count": 1}', "json", False)

        def test_missing_files_are_stale(self):
            for kind, expected in [("text", ""), ("markdown", table), ("json", "{}")]:
                with self.subTest(kind=kind):
                    self.assertFalse(matches(self.path, expected, kind=kind))

        def test_generated_code_remains_exact(self):
            self.check_match("const x = 1;\n", "const x=1;\n", "text", False)
            self.check_match("const x=1;\n", "const x=1;\n", "text")

        def test_generation_preserves_equivalent_files(self):
            for kind, actual, expected in [
                ("markdown", formatted_table.replace("\n", "\r\n"), table),
                ("json", '{ "b": [1, 2], "a": 3 }', '{"a": 3, "b": [1, 2]}'),
            ]:
                with self.subTest(kind=kind):
                    self.path.write_bytes(actual.encode("utf-8"))
                    modified = self.path.stat().st_mtime_ns
                    for check in [True, False]:
                        self.assertTrue(
                            check_or_write(self.path, expected, check=check, kind=kind)
                        )
                    self.assertEqual(self.path.read_bytes(), actual.encode("utf-8"))
                    self.assertEqual(self.path.stat().st_mtime_ns, modified)

        def test_only_generation_writes_missing_or_changed_files(self):
            self.path = self.path / "nested/output"
            self.assertFalse(check_or_write(self.path, "original\n", check=True))
            self.assertFalse(self.path.parent.exists())
            self.assertTrue(check_or_write(self.path, "original\n", check=False))
            self.assertFalse(check_or_write(self.path, "changed\n", check=True))
            self.assertEqual(self.path.read_bytes(), b"original\n")
            self.assertTrue(check_or_write(self.path, "changed\n", check=False))
            self.assertEqual(self.path.read_bytes(), b"changed\n")

    created_directory = not temporary_root.exists()
    temporary_root.mkdir(exist_ok=True)
    try:
        suite = unittest.defaultTestLoader.loadTestsFromTestCase(GeneratedFilesTest)
        result = unittest.TextTestRunner().run(suite)
        return 0 if result.wasSuccessful() else 1
    finally:
        if created_directory and not any(temporary_root.iterdir()):
            temporary_root.rmdir()


def main() -> int:
    import argparse

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--self-test", action="store_true", help="Run format and write checks"
    )
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    parser.print_help()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

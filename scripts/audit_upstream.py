#!/usr/bin/env python3
"""审计固定版本 Unitree C++ SDK 的公开接口与 DDS 消息。

仅解析固定上游源码，不建立 DDS 连接。
--json 输出机器可读清单；--check MANIFEST 核对 cpp_methods、messages 两类清单。清单保留方法签名，分别记录重载。
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def sdk_source(path: Path) -> dict:
    """记录唯一依赖声明与实际输入指纹；不要求源码目录是 Git 仓库。"""
    declaration = (ROOT / "build.zig.zon").read_text(encoding="utf-8")
    match = re.search(r"\.unitree_sdk2_native\s*=\s*\.\{(.*?)\}", declaration, re.S)
    if not match:
        raise ValueError("Missing unitree_sdk2_native dependency in build.zig.zon")
    dependency = {}
    for name in ("url", "hash"):
        value = re.search(rf'\.{name}\s*=\s*("[^"\n]+")', match[1])
        if not value:
            raise ValueError(f"Missing SDK dependency {name}")
        dependency[name] = json.loads(value[1])
    revision = re.fullmatch(
        r"https://github\.com/unitreerobotics/unitree_sdk2/archive/([0-9a-f]{40})\.tar\.gz",
        dependency["url"],
    )
    if not revision:
        raise ValueError("SDK dependency must pin an official C++ SDK commit")
    dependency["revision"] = revision[1]
    headers = path / "include/unitree"
    if (
        not (headers / "robot/client/client.hpp").is_file()
        or not (headers / "idl").is_dir()
    ):
        raise ValueError(f"Invalid C++ SDK directory: {path}")
    fingerprint = hashlib.sha256()
    for header in sorted(headers.rglob("*"), key=lambda p: p.as_posix()):
        if header.suffix not in {".h", ".hpp"} or not header.is_file():
            continue
        fingerprint.update(header.relative_to(path).as_posix().encode("utf-8") + b"\0")
        fingerprint.update(header.read_text(encoding="utf-8").encode("utf-8") + b"\0")
    return {"dependency": dependency, "headers_sha256": fingerprint.hexdigest()}


def scrub_cpp(source: str) -> str:
    return re.sub(
        r'//[^\n]*|/\*.*?\*/|"(?:\\.|[^"\\])*"',
        lambda match: " " * len(match.group()),
        source,
        flags=re.S,
    )


def matching_brace(source: str, start: int) -> int:
    depth = 0
    for index in range(start, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return index
    raise ValueError("Unbalanced upstream C++ class")


def _without_bodies(source: str, sanitized: str) -> str:
    """Keep declarations and replace inline bodies with spaces."""
    flat = []
    index = 0
    while index < len(source):
        if sanitized[index] == "{":
            end = matching_brace(sanitized, index)
            flat.append(";" + " " * (end - index))
            index = end + 1
        else:
            flat.append(source[index])
            index += 1
    return "".join(flat)


def cpp_clients(root: Path) -> list[dict]:
    clients = []
    robot_root = root / "include/unitree/robot"
    # Discover inheritance across all robot headers; a new model or filename
    # must not disappear merely because a handwritten robot list is stale.
    for path in sorted(robot_root.rglob("*.hpp"), key=lambda p: p.as_posix()):
        relative = path.relative_to(robot_root)
        source = path.read_text(encoding="utf-8")
        clean = scrub_cpp(source)
        for match in re.finditer(
            r"\bclass\s+(\w+)\s*:\s*public\s+Client\b[^\{]*\{", clean
        ):
            name = match.group(1)
            start = match.end()
            body = clean[start : matching_brace(clean, start - 1)]
            body = _without_bodies(body, body)
            access = "private"
            methods = []
            namespace = "/".join(relative.parts[:-1])
            for fragment in re.split(r"(;|\b(?:public|private|protected)\s*:)", body):
                access_match = re.fullmatch(r"(public|private|protected)\s*:", fragment)
                if access_match:
                    access = access_match.group(1)
                    continue
                if access != "public":
                    continue
                method = re.search(
                    r"\b(\w+)\s*\((.*?)\)\s*(?:const)?\s*(?:override)?\s*$",
                    fragment,
                    re.S,
                )
                if not method or method.group(1) == name or "~" in fragment:
                    continue
                method_name, parameters = method.groups()
                parameters = re.sub(r"\s+", " ", parameters).strip()
                prefix = fragment[: method.start()].strip()
                if not prefix:
                    continue
                key = f"{namespace}/{name}.{method_name}({parameters})"
                methods.append(
                    {
                        "name": method_name,
                        "parameters": parameters,
                        "return": prefix,
                        "key": key,
                    }
                )
            clients.append(
                {
                    "namespace": namespace,
                    "class": name,
                    "source": path.relative_to(root).as_posix(),
                    "methods": methods,
                }
            )
    return clients


def messages(cpp: Path) -> dict:
    cpp_types = {}
    paths = sorted((cpp / "include").rglob("*.hpp"), key=lambda p: p.as_posix())
    for path in paths:
        source = path.read_text(encoding="utf-8")
        if "REGISTER_TOPIC_TYPE(" not in source:
            continue
        # Generated DDS topic trait specializations contain the canonical DDS name.
        match = re.search(r'return\s+"([\w:]+_)"', source)
        if match:
            name = match.group(1).replace("::", ".")
            cpp_types[name] = path.relative_to(cpp).as_posix()
    return cpp_types


def constants(cpp: Path) -> list[dict]:
    """Literal service names, versions, API IDs and error IDs (not computed enums)."""
    cpp_constants = []
    robot_root = cpp / "include/unitree/robot"
    for path in sorted(robot_root.rglob("*.hpp"), key=lambda p: p.as_posix()):
        if not path.name.endswith(("_api.hpp", "_error.hpp")):
            continue
        relative = path.relative_to(robot_root).as_posix()
        source = path.read_text(encoding="utf-8")
        for match in re.finditer(
            r'\bconst\s+(?:std::string|int32_t|int64_t|uint32_t)\s+(\w+)\s*=\s*("[^"]*"|-?\d+)\s*;',
            source,
        ):
            cpp_constants.append(
                {
                    "source": relative,
                    "name": match.group(1),
                    "value": json.loads(match.group(2)),
                }
            )
        for match in re.finditer(
            r'UT_DECL_ERR\s*\(\s*(\w+)\s*,\s*(-?\d+)\s*,\s*"([^"]*)"', source
        ):
            cpp_constants.append(
                {
                    "source": relative,
                    "name": match.group(1),
                    "value": int(match.group(2)),
                    "description": match.group(3),
                }
            )
    return cpp_constants


def wrapper_surface(cpp: Path) -> list[dict]:
    """Read the convenience layer separately from the RPC Client hierarchy.

    Retains checksums and source signatures, including public state fields.
    Templates and virtual hooks are reported, not interpreted as robot RPCs.
    """
    root = cpp / "include/unitree/dds_wrapper"
    headers = []
    for path in sorted(root.rglob("*"), key=lambda p: p.as_posix()):
        if path.suffix not in {".h", ".hpp"}:
            continue
        source = path.read_text(encoding="utf-8")
        clean = scrub_cpp(source)
        entry = {
            "source": path.relative_to(root).as_posix(),
            "sha256": hashlib.sha256(source.encode("utf-8")).hexdigest(),
            "classes": [],
            "enums": [],
            "functions": [],
            "types": [],
            "constants": [],
        }
        for alias in re.finditer(r"\btypedef\s+(?:union|struct)\s*\{", clean):
            end = matching_brace(clean, alias.end() - 1)
            name = re.match(r"\s*(\w+)\s*;", clean[end + 1 :])
            if name:
                entry["types"].append(name.group(1))
        for array in re.finditer(
            r"\b(?:static\s+)?const(?:expr)?\s+std::array<[^>]+>\s+(\w+)\s*=\s*\{([^}]+)\}",
            clean,
            re.S,
        ):
            entry["constants"].append(
                {
                    "name": array.group(1),
                    "values": [
                        value.strip()
                        for value in array.group(2).split(",")
                        if value.strip()
                    ],
                }
            )
        for enum in re.finditer(
            r"\benum\s+(?:class\s+)?(\w+)\s*\{([^}]*)\}", clean, re.S
        ):
            values = {}
            value = -1
            for fragment in enum.group(2).split(","):
                item = re.fullmatch(r"\s*(\w+)\s*(?:=\s*(\d+))?\s*", fragment)
                if item:
                    value = int(item.group(2)) if item.group(2) else value + 1
                    values[item.group(1)] = value
            entry["enums"].append({"name": enum.group(1), "values": values})
        for cls in re.finditer(r"\bclass\s+(\w+)\s*(?::[^{}]+)?\{", clean):
            if re.search(r"\benum\s*$", clean[max(0, cls.start() - 12) : cls.start()]):
                continue
            class_name = cls.group(1)
            end = matching_brace(clean, cls.end() - 1)
            clean_body = clean[cls.end() : end]
            body = re.sub(
                r"//[^\n]*|/\*.*?\*/",
                lambda match: " " * len(match.group()),
                source[cls.end() : end],
                flags=re.S,
            )
            body = _without_bodies(body, clean_body)
            access = "private"
            members = []
            for fragment in re.split(r"(;|\b(?:public|private|protected)\s*:)", body):
                access_match = re.fullmatch(r"(public|private|protected)\s*:", fragment)
                if access_match:
                    access = access_match.group(1)
                elif access == "public" and fragment.strip() and fragment != ";":
                    signature = re.sub(r"\s+", " ", fragment).strip()
                    if signature.startswith("using "):
                        continue
                    # Constructor initializers are not separate public methods.
                    constructor = re.search(rf"\b{class_name}\s*\(", signature)
                    if constructor and not signature.startswith("~"):
                        depth = 1
                        end = constructor.end()
                        while depth and end < len(signature):
                            depth += (signature[end] == "(") - (signature[end] == ")")
                            end += 1
                        signature = signature[:end]
                    members.append(signature)
            entry["classes"].append({"name": class_name, "public_members": members})
        for function in re.finditer(
            r"\binline\s+(\w+)\s+(\w+)\s*\(([^)]*)\)\s*\{", clean
        ):
            entry["functions"].append(
                {
                    "name": function.group(2),
                    "signature": re.sub(r"\s+", " ", function.group(0)[:-1]).strip(),
                }
            )
        headers.append(entry)
    return headers


def inventory(cpp: Path) -> dict:
    source = sdk_source(cpp)
    clients = cpp_clients(cpp)
    result = {
        "sdk": source,
        "cpp_clients": clients,
        "messages": messages(cpp),
        "constants": constants(cpp),
        "dds_wrappers": wrapper_surface(cpp),
    }
    result["counts"] = {
        "cpp_clients": len(clients),
        "cpp_methods_with_init_and_overloads": sum(len(c["methods"]) for c in clients),
        "dds_messages": len(result["messages"]),
        "cpp_api_error_literals": len(result["constants"]),
        "dds_wrapper_headers": len(result["dds_wrappers"]),
        "dds_wrapper_classes": sum(len(h["classes"]) for h in result["dds_wrappers"]),
    }
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--sdk", type=Path, required=True, help="SDK directory resolved by Zig"
    )
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--check", type=Path, metavar="MANIFEST")
    args = parser.parse_args()
    result = inventory(args.sdk)
    if args.check:
        manifest = json.loads(args.check.read_text(encoding="utf-8"))
        expected = {
            "cpp_methods": {
                method["key"] for c in result["cpp_clients"] for method in c["methods"]
            },
            "messages": set(result["messages"]),
        }
        differences = {}
        if manifest.get("sdk") != result["sdk"]:
            differences["sdk"] = {
                "expected": result["sdk"],
                "recorded": manifest.get("sdk"),
            }
        for key, values in expected.items():
            actual = {
                row if isinstance(row, str) else row["upstream"]
                for row in manifest.get(key, [])
            }
            if values != actual:
                differences[key] = {
                    "missing": sorted(values - actual),
                    "extra": sorted(actual - values),
                }
        if differences:
            print(json.dumps(differences, ensure_ascii=False, indent=2))
            return 1
        print("All source inventory keys are represented by the binding manifest.")
    elif args.json:
        print(json.dumps(result, ensure_ascii=False, indent=2))
    else:
        print(
            json.dumps(
                {
                    "sdk": result["sdk"],
                    "counts": result["counts"],
                },
                ensure_ascii=False,
                indent=2,
            )
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())

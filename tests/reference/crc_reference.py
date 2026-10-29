#!/usr/bin/env python3
"""对照固定 C++ SDK 的字段布局与 CRC 实现，核验 Zig 的四组测试向量。

从 Zig 传入的 SDK 目录读取字段布局；--emit-cpp 生成原生对照源码，
--native-result 核验构建图中官方 C++ 消息和 CRC 程序的输出。脚本不启动子构建。
"""

from __future__ import annotations

import argparse
import ctypes
import json
from pathlib import Path
import re
import struct

ROOT = Path(__file__).resolve().parents[2]
SCALARS = {
    "uint8_t": ctypes.c_uint8,
    "uint16_t": ctypes.c_uint16,
    "uint32_t": ctypes.c_uint32,
    "int8_t": ctypes.c_int8,
    "int16_t": ctypes.c_int16,
    "int32_t": ctypes.c_int32,
    "float": ctypes.c_float,
}
FORMATS = {"go2.LowCmd": 812, "go2.LowState": 1180, "hg.LowCmd": 1004, "hg.LowState": 2092}


class Layouts:
    def __init__(self, sdk: Path):
        self.sdk = sdk
        self.fields = {}
        self.types = {}

    def resolve(self, name: str):
        if name in SCALARS:
            return SCALARS[name]
        if name in self.types:
            return self.types[name]
        group, message = name.split(".")
        path = self.sdk / f"include/unitree/idl/{group}/{message}_.hpp"
        source = path.read_text(encoding="utf-8")
        body = source.split("private:", 1)[1].split("public:", 1)[0]
        fields = []
        for declaration in body.split(";"):
            declaration = declaration.strip()
            if not declaration:
                continue
            match = re.fullmatch(r"(.+?)\s+(\w+)_\s*(?:=.*)?", declaration)
            if not match:
                raise ValueError(f"Unsupported SDK field: {path}: {declaration}")
            type_name, field_name = match.groups()
            array = re.fullmatch(r"std::array<(.+),\s*(\d+)>", type_name)
            length = int(array[2]) if array else None
            type_name = array[1].strip() if array else type_name
            nested = re.fullmatch(r"::unitree_(go|hg)::msg::dds_::(\w+)_", type_name)
            if nested:
                type_name = ("go2" if nested[1] == "go" else "hg") + "." + nested[2]
            fields.append((type_name, field_name, length))
        native_fields = []
        for type_name, field_name, length in fields:
            field_type = self.resolve(type_name)
            native_fields.append((field_name, field_type * length if length else field_type))
        self.fields[name] = fields
        self.types[name] = type(message, (ctypes.LittleEndianStructure,), {"_fields_": native_fields})
        return self.types[name]

    def fixture(self, name: str):
        counter = 0
        assignments = []

        def value(type_name: str, expression: str):
            nonlocal counter
            if type_name in self.fields:
                fields = {}
                for child_type, field_name, length in self.fields[type_name]:
                    accessor = expression + "." + field_name + "()"
                    if length:
                        array = self.resolve(child_type) * length
                        fields[field_name] = array(*(value(child_type, f"{accessor}[{i}]") for i in range(length)))
                    else:
                        fields[field_name] = value(child_type, accessor)
                return self.resolve(type_name)(**fields)
            counter += 1
            if type_name == "float":
                result = (counter % 13 - 6) * 0.125
                literal = repr(result) + "f"
            elif type_name.startswith("uint"):
                result = counter % 97
                literal = str(result)
            else:
                result = -(counter % 17)
                literal = str(result)
            assignments.append(f"    {expression} = {literal};")
            return result

        return value(name, "message"), assignments


def checksum(words) -> int:
    crc = 0xffffffff
    for word in words:
        for bit in range(31, -1, -1):
            carry = crc >> 31
            crc = (crc << 1) & 0xffffffff
            if carry ^ ((word >> bit) & 1):
                crc ^= 0x04c11db7
    return crc


def native_source(layouts: Layouts) -> str:
    lines = ["#include <cstdint>", "#include <cstdio>", "#include <cstring>", "#include <type_traits>",
             '#include "unitree/dds_wrapper/common/crc.h"']
    for name in FORMATS:
        group, message = name.split(".")
        lines.append(f'#include "unitree/idl/{group}/{message}_.hpp"')
    lines += ["int main() {", '    if (crc16_core(reinterpret_cast<const uint8_t*>("123456789"), 9) != 0x4b37) return 1;']
    for name, size in FORMATS.items():
        group, message = name.split(".")
        namespace = "unitree_go" if group == "go2" else "unitree_hg"
        lines += ["    {", f"    using T = {namespace}::msg::dds_::{message}_;",
                  "    static_assert(std::is_trivially_copyable_v<T> && std::is_standard_layout_v<T>);",
                  f"    static_assert(sizeof(T) == {size});", "    T message;",
                  "    std::memset(&message, 0, sizeof(message));"]
        _, assignments = layouts.fixture(name)
        lines += assignments
        lines += [f"    uint32_t words[{size // 4}];", "    std::memcpy(words, &message, sizeof(message));",
                  f'    std::printf("{name} %08x\\n", crc32_core(words, {size // 4 - 1}));', "    }"]
    lines += ["}"]
    return "\n".join(lines) + "\n"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sdk", type=Path, required=True, help="SDK directory resolved by Zig")
    parser.add_argument("--zig", type=Path, default=ROOT / "src/crc.zig")
    parser.add_argument("--emit-cpp", type=Path, help="Write the native reference source for Zig to compile")
    parser.add_argument("--native-result", type=Path, help="Verify the native reference executable's captured output")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    crc_header = (args.sdk / "include/unitree/dds_wrapper/common/crc.h").read_text(encoding="utf-8")
    table_body = re.search(r"wCRCTable\[\]\s*=\s*\{(.*?)\}", crc_header, re.S).group(1)
    table = [int(value, 16) for value in re.findall(r"0[xX][0-9a-fA-F]+", table_body)]
    if len(table) != 256:
        raise ValueError("Upstream CRC16 table length changed")
    crc16 = 0xffff
    for byte in b"123456789":
        crc16 = (crc16 >> 8) ^ table[(byte ^ crc16) & 0xff]
    if crc16 != 0x4b37:
        raise ValueError("Upstream CRC16 reference table changed")
    layouts = Layouts(args.sdk)
    results = {}
    for name, size in FORMATS.items():
        native_type = layouts.resolve(name)
        if ctypes.sizeof(native_type) != size or native_type.crc.offset != size - 4:
            raise ValueError(f"SDK low-level layout changed: {name}")
        message, _ = layouts.fixture(name)
        data = bytes(message)[:-4]
        results[name] = checksum(word for (word,) in struct.iter_unpack("<I", data))
    expected = dict(re.findall(r"// reference: ([\w.]+) = (0x[0-9a-fA-F]+)", args.zig.read_text(encoding="utf-8")))
    if {name: int(value, 16) for name, value in expected.items()} != results:
        raise ValueError(f"Zig CRC fixtures differ from C++ SDK layout: {results}")
    if args.emit_cpp:
        args.emit_cpp.write_text(native_source(layouts), encoding="utf-8", newline="\n")
        return
    if args.native_result:
        output = args.native_result.read_text(encoding="utf-8")
        native = {name: int(value, 16) for name, value in (line.split() for line in output.splitlines())}
        if native != results:
            raise ValueError("Native C++ message CRC differs from field-layout reference")
    if args.json:
        print(json.dumps({name: f"0x{value:08x}" for name, value in results.items()}, indent=2))
    else:
        for name, value in results.items():
            print(f"{name}: {value:#010x}")
        print("C++ SDK field layouts and CRC16 table match" + ("; native C++ CRC matches" if args.native_result else ""))


if __name__ == "__main__":
    main()

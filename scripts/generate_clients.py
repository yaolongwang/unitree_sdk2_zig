#!/usr/bin/env python3
"""从固定版本的 Unitree C++ 客户端头文件生成类型化 C ABI 和 Zig 接口。

不暴露 C++ 对象布局；遇到未知签名立即失败，避免静默遗漏接口。
补充协议的动作表和常量保存在 scripts/protocol_extensions.json。
使用 --check 核对已生成文件是否与生成器和上游一致。
"""

from __future__ import annotations

import argparse
import collections
import copy
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SDK: Path | None = None
PROTOCOL_METADATA = ROOT / "scripts/protocol_extensions.json"
ROBOTS = {"a2", "as2", "b2", "g1", "go2", "h1", "h2", "r1"}


def strip_comments(s):
    return re.sub(r"//[^\n]*|/\*.*?\*/", lambda m: " " * len(m[0]), s, flags=re.S)


def block(s, start):
    depth = 1
    quote = None
    i = start + 1
    while depth:
        ch = s[i]
        if quote:
            if ch == "\\":
                i += 1
            elif ch == quote:
                quote = None
        elif ch in "\"'":
            quote = ch
        elif ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
        i += 1
    return s[start + 1 : i - 1], i


def top_level(s):
    out = []
    i = 0
    while i < len(s):
        if s[i] == "{":
            _, end = block(s, i)
            out.append(" " * (end - i))
            i = end
        else:
            out.append(s[i])
            i += 1
    return "".join(out)


def split_params(s):
    depth = 0
    parts = []
    last = 0
    for i, ch in enumerate(s):
        if ch == "<":
            depth += 1
        elif ch == ">":
            depth -= 1
        elif ch == "," and depth == 0:
            parts.append(s[last:i].strip())
            last = i + 1
    if s[last:].strip():
        parts.append(s[last:].strip())
    return parts


def snake(name):
    s = re.sub(r"([A-Z]+)([A-Z][a-z])", r"\1_\2", name)
    return re.sub(r"([a-z0-9])([A-Z])", r"\1_\2", s).lower().strip("_")


def camel(name):
    parts = snake(name).split("_")
    return parts[0] + "".join(p.title() for p in parts[1:])


def parse():
    if SDK is None or not (SDK / "unitree/robot/client/client.hpp").is_file():
        raise ValueError("Provide a valid C++ SDK directory with --sdk")
    clients = []
    for path in sorted((SDK / "unitree/robot").glob("*/*/*client.hpp"), key=lambda p: p.as_posix()):
        rel = path.relative_to(SDK)
        robot, service = rel.parts[2:4]
        if robot not in ROBOTS:
            continue
        text = strip_comments(path.read_text(encoding="utf-8"))
        matches = list(
            re.finditer(r"class\s+(\w+Client)\s*:\s*public\s+Client\s*\{", text)
        )
        if len(matches) != 1:
            raise ValueError(f"Expected one Client in {path}")
        cls = matches[0][1]
        body, _ = block(text, matches[0].end() - 1)
        flat = top_level(body)
        public = []
        access = "private"
        for part in re.split(r"\b(public|protected|private)\s*:", flat):
            if part in ("public", "protected", "private"):
                access = part
            elif access == "public":
                public.append(part)
        declarations = "\n".join(public)
        methods = []
        for m in re.finditer(r"\b(void|int32_t)\s+(\w+)\s*\(([^)]*)\)", declarations):
            if m[2] == "Init":
                continue
            params = []
            for index, param in enumerate(split_params(m[3])):
                param, _, default = param.partition("=")
                param = param.strip()
                nm = re.search(r"\b([a-zA-Z_]\w*)\s*$", param)
                if nm and nm.start() > 0 and param[nm.start() - 1] != ":":
                    name = nm[1]
                    typ = param[: nm.start()].strip()
                else:
                    name = f"value{index}"
                    typ = param
                typ = re.sub(r"\s+", " ", typ)
                typ = re.sub(r"\s*([<>,&])\s*", r"\1", typ)
                output = (
                    "&" in typ
                    and not typ.startswith("const ")
                    and m[2] not in ("SetPunchApi", "TrajectoryFollow")
                )
                params.append(
                    dict(name=name, type=typ, output=output, default=default.strip())
                )
            methods.append(dict(name=m[2], result=m[1], params=params))
        counts = collections.Counter(m["name"] for m in methods)
        for method in methods:
            name = snake(method["name"])
            if counts[method["name"]] > 1:
                if method["name"] == "Move":
                    name += "_with_mode" if len(method["params"]) == 4 else ""
                elif method["name"] == "ExecuteAction":
                    name += (
                        "_by_name" if "string" in method["params"][0]["type"] else ""
                    )
                elif method["name"] == "Meta":
                    name += "_json" if "string" in method["params"][-1]["type"] else ""
                else:
                    raise ValueError(f"Unknown overload {robot}/{service}/{method}")
            method["binding"] = name
        constructor = re.search(r"\b" + cls + r"\s*\(([^)]*)\)", declarations)
        ctor = constructor[1].strip()
        if ctor and "bool enableLease" not in ctor:
            raise ValueError(f"Unknown constructor {ctor}")
        clients.append(
            dict(
                robot=robot,
                service=service,
                cls=cls,
                header=rel.as_posix(),
                methods=methods,
                lease=bool(ctor),
            )
        )
    return clients


SCALARS = {
    "bool": ("bool", "bool"),
    "float": ("float", "f32"),
    "double": ("double", "f64"),
    "int": ("int32_t", "i32"),
    "int32_t": ("int32_t", "i32"),
    "uint8_t": ("uint8_t", "u8"),
}
VECTOR_TYPES = {
    "float": ("usdk_client_floats", "f32"),
    "int": ("usdk_client_ints", "i32"),
    "uint8_t": ("usdk_bytes", "u8"),
    "std::string": ("usdk_client_strings", "raw.usdk_string"),
    "ServiceState": ("usdk_client_service_states", "raw.usdk_client_service_state"),
}
KEYWORDS = {
    "type",
    "error",
    "test",
    "resume",
    "suspend",
    "switch",
    "defer",
    "var",
    "const",
    "fn",
    "align",
    "opaque",
    "packed",
    "enum",
    "union",
    "struct",
}


def zid(s):
    return '@"' + s + '"' if s in KEYWORDS else s


def info(param, client):
    typ = param["type"].removeprefix("const ").replace("&", "")
    robot = client["robot"]
    if typ in SCALARS:
        ct, zt = SCALARS[typ]
        return dict(kind="scalar", cpp=typ, c=ct, z=zt, dynamic=False)
    if typ == "InternalFsmMode":
        return dict(
            kind="enum",
            cpp=f"unitree::robot::{robot}::{typ}",
            c="int32_t",
            z="InternalFsmMode",
            dynamic=False,
        )
    if typ == "std::string":
        return dict(
            kind="string", cpp=typ, c="usdk_string", z="[]const u8", dynamic=True
        )
    if typ == "ConfigMeta":
        return dict(
            kind="meta",
            cpp=f"unitree::robot::{robot}::{typ}",
            c="usdk_client_config_meta",
            z="raw.usdk_client_config_meta",
            dynamic=True,
        )
    if typ == "std::map<std::string,std::string>":
        return dict(
            kind="map",
            cpp=typ,
            c="usdk_client_string_map",
            z="[]const raw.usdk_client_string_pair",
            dynamic=True,
        )
    if typ == "ConfigChangeStatusCallback":
        return dict(
            kind="callback",
            cpp=f"unitree::robot::{robot}::{typ}",
            c="usdk_config_callback",
            z="raw.usdk_config_callback",
            dynamic=False,
        )
    m = re.fullmatch(r"std::vector<(.+)>", typ)
    if m:
        inner = m[1]
        if inner.endswith("PathPoint"):
            return dict(
                kind="path",
                cpp=f"std::vector<unitree::robot::{robot}::PathPoint>",
                c=f"usdk_client_{robot}_path",
                z=f"[]const raw.usdk_client_{robot}_path_point",
                dynamic=True,
            )
        ct, zt = VECTOR_TYPES[inner]
        cpp = (
            typ
            if inner != "ServiceState"
            else f"std::vector<unitree::robot::{robot}::ServiceState>"
        )
        return dict(
            kind="vector", inner=inner, cpp=cpp, c=ct, z="[]const " + zt, dynamic=True
        )
    raise ValueError(f"Unbound type {typ}")


HEADER = """/* Generated by scripts/generate_clients.py; do not edit. */
#ifndef USDK_CLIENTS_H
#define USDK_CLIENTS_H
#include "usdk.h"
#include <stdbool.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct usdk_client_output usdk_client_output;
/* Output views are valid until this owner is destroyed. Output slots must not
 * contain a live owned result; release it before reuse. On failure all output
 * slots are zeroed and no ownership is transferred. */
void usdk_client_output_destroy(usdk_client_output* owner);
typedef struct { const float* data; size_t len; } usdk_client_floats;
typedef struct { const int32_t* data; size_t len; } usdk_client_ints;
typedef struct { const usdk_string* data; size_t len; } usdk_client_strings;
typedef struct { usdk_string key; usdk_string value; } usdk_client_string_pair;
typedef struct { const usdk_client_string_pair* data; size_t len; } usdk_client_string_map;
typedef struct { usdk_string name; int32_t status; int32_t protect; } usdk_client_service_state;
typedef struct { const usdk_client_service_state* data; size_t len; } usdk_client_service_states;
typedef struct { usdk_string name; usdk_string last_modified; int32_t size; int32_t epoch; } usdk_client_config_meta;
typedef struct { float t_from_start; float x; float y; float yaw; } usdk_client_a2_path_point;
typedef struct { const usdk_client_a2_path_point* data; size_t len; } usdk_client_a2_path;
typedef struct { float time_from_start; float x; float y; float yaw; float vx; float vy; float vyaw; } usdk_client_b2_path_point;
typedef struct { const usdk_client_b2_path_point* data; size_t len; } usdk_client_b2_path;
/* Callback arguments are borrowed only during the invocation. Do not destroy the client inside it. */
typedef void (*usdk_config_callback)(void* context, usdk_string name, usdk_string status);
"""

HELPERS = """// Generated by scripts/generate_clients.py; do not edit.
#pragma once
#include "internal.hpp"
#include "usdk_clients.h"
#include <memory>
#include <vector>
#include <string>
#include <stdexcept>
#include <utility>
#include <map>
#include <limits>

struct usdk_client_output {
    std::vector<std::shared_ptr<void>> storage;
    template<class T> T& keep(T value) {
        auto item = std::make_shared<T>(std::move(value));
        storage.push_back(item);
        return *item;
    }
};

namespace usdk_clients {
template<class T> void check_length(size_t len) {
    if (len > static_cast<size_t>(std::numeric_limits<ptrdiff_t>::max()) / sizeof(T))
        throw std::invalid_argument("input sequence length exceeds addressable range");
}
template<class T> std::vector<T> copy(const T* data, size_t len) {
    if (len == 0) return {};
    if (!data) throw std::invalid_argument("null input sequence");
    check_length<T>(len);
    return std::vector<T>(data, data + len);
}
inline usdk_string view(const std::string& value) { return {value.data(), value.size()}; }
inline void config_callback(usdk_config_callback callback, void* context,
                            const std::string& name, const std::string& status) noexcept {
    (void)usdk::guard([&]() -> int32_t {
        if (!callback) return usdk::fail("null configuration callback");
        callback(context, view(name), view(status));
        return 0;
    });
}
inline usdk_string output(usdk_client_output& owner, std::string value) {
    return view(owner.keep(std::move(value)));
}
inline usdk_client_floats output(usdk_client_output& owner, std::vector<float> value) {
    auto& saved = owner.keep(std::move(value)); return {saved.data(), saved.size()};
}
inline usdk_client_ints output(usdk_client_output& owner, std::vector<int> value) {
    static_assert(sizeof(int) == sizeof(int32_t));
    auto& saved = owner.keep(std::move(value)); return {saved.data(), saved.size()};
}
inline usdk_bytes output(usdk_client_output& owner, std::vector<uint8_t> value) {
    auto& saved = owner.keep(std::move(value)); return {saved.data(), saved.size()};
}
inline usdk_client_strings output(usdk_client_output& owner, std::vector<std::string> value) {
    auto& saved = owner.keep(std::move(value));
    std::vector<usdk_string> views;
    for (const auto& item : saved) views.push_back(view(item));
    auto& result = owner.keep(std::move(views)); return {result.data(), result.size()};
}
inline usdk_client_string_map output(usdk_client_output& owner, std::map<std::string, std::string> value) {
    auto& saved = owner.keep(std::move(value));
    std::vector<usdk_client_string_pair> views;
    for (const auto& item : saved) views.push_back({view(item.first), view(item.second)});
    auto& result = owner.keep(std::move(views)); return {result.data(), result.size()};
}
template<class T> usdk_client_service_states services(usdk_client_output& owner, std::vector<T> value) {
    auto& saved = owner.keep(std::move(value));
    std::vector<usdk_client_service_state> views;
    for (const auto& item : saved) views.push_back({view(item.name), item.status, item.protect});
    auto& result = owner.keep(std::move(views)); return {result.data(), result.size()};
}
template<class T> usdk_client_config_meta meta(usdk_client_output& owner, T value) {
    auto& saved = owner.keep(std::move(value));
    return {view(saved.name), view(saved.lastModified), saved.size, saved.epoch};
}
} // namespace usdk_clients
"""

ZIG_HEADER = """//! Typed wrappers for every public C++ robot client method.
//! Generated by scripts/generate_clients.py; do not edit.
//! Floating-point RPC inputs must be finite. Serialize use of each client handle.
const raw = @import("raw");
const core = @import("core.zig");

pub const InternalFsmMode = enum(i32) { last = 0, passive = 1, walkrun = 2 };
pub const ConfigMeta = raw.usdk_client_config_meta;
pub const ServiceState = raw.usdk_client_service_state;
pub const StringPair = raw.usdk_client_string_pair;
pub const ConfigChangeCallback = raw.usdk_config_callback;

/// Owns all dynamic memory reachable through value. Move ownership; do not copy it.
pub fn Owned(comptime T: type) type {
    return struct {
        value: T,
        owner: ?*raw.usdk_client_output,
        pub fn deinit(self: *@This()) void {
            raw.usdk_client_output_destroy(self.owner);
            self.* = undefined;
        }
    };
}

fn string(value: []const u8) raw.usdk_string {
    return .{ .data = @ptrCast(value.ptr), .len = value.len };
}
/// Borrows a nested string from an owned result or configuration callback.
pub fn stringSlice(value: raw.usdk_string) []const u8 {
    if (value.len == 0) return &.{};
    return @as([*]const u8, @ptrCast(value.data))[0..value.len];
}
fn slice(comptime T: type, value: anytype) []const T {
    if (value.len == 0) return &.{};
    return @as([*]const T, @ptrCast(@alignCast(value.data)))[0..value.len];
}
"""

PROTOCOL_EXTENSIONS = {
    ("b2", "sport"): """namespace usdk_clients {
class B2SportClient final : public unitree::robot::b2::SportClient {
public:
    using SportClient::SportClient;
    void Init() {
        SportClient::Init();
        RegistApi(1051, 0);
    }
    int32_t FreeEuler(bool flag) {
        std::string response;
        return Call(1051, flag ? "{\\"data\\":true}" : "{\\"data\\":false}", response);
    }
};
} // namespace usdk_clients
""",
    ("r1", "loco"): """namespace usdk_clients {
class R1LocoClient final : public unitree::robot::r1::LocoClient {
    bool first_shake_hand_stage_ = true; // The first automatic toggle requests stage 2.
public:
    void Init() {
        LocoClient::Init();
        RegistApi(7106, 0);
    }
    int32_t SetTaskId(double task_id) {
        if (!std::isfinite(task_id)) return usdk::fail("task id must be finite");
        unitree::common::JsonMap json;
        unitree::common::ToJson(task_id, json["data"]);
        std::string response;
        return Call(7106, unitree::common::ToJsonString(json), response);
    }
    int32_t WaveHand(bool turn_flag) { return SetTaskId(turn_flag ? 1 : 0); }
    int32_t ShakeHand(int stage) {
        if (stage == 0) first_shake_hand_stage_ = false;
        else if (stage == 1) first_shake_hand_stage_ = true;
        else first_shake_hand_stage_ = !first_shake_hand_stage_;
        return SetTaskId(first_shake_hand_stage_ ? 3 : 2);
    }
};
} // namespace usdk_clients
""",
}


def implementation(c):
    if c["service"] == "audio":
        return f"usdk_clients::{c['robot'].upper()}AudioClientCompat"
    return {
        ("b2", "sport"): "usdk_clients::B2SportClient",
        ("r1", "loco"): "usdk_clients::R1LocoClient",
        ("g1", "arm"): "usdk_clients::G1ArmActionClientCompat",
    }.get((c["robot"], c["service"]), f"unitree::robot::{c['robot']}::{c['cls']}")


def audio_extension(c):
    robot = c["robot"]
    return f"""namespace usdk_clients {{
// The pinned upstream PlayStop discards Call's status and always returns zero.
// Keep the same request and expose the real result at the FFI boundary.
class {robot.upper()}AudioClientCompat final : public unitree::robot::{robot}::AudioClient {{
public:
    int32_t PlayStop(const std::string& app_name) {{
        unitree::robot::{robot}::PlayStopParameter parameter;
        parameter.app_name = app_name;
        std::string response;
        return Call(unitree::robot::{robot}::ROBOT_API_ID_AUDIO_STOP_PLAY,
                    unitree::common::ToJsonString(parameter), response);
    }}
}};
}} // namespace usdk_clients
"""


def protocol_metadata():
    metadata = json.loads(PROTOCOL_METADATA.read_text(encoding="utf-8"))
    if metadata["schema_version"] != 1:
        raise ValueError("Unsupported supplemental protocol metadata schema")
    return metadata


def g1_arm_extension():
    entries = ",\n".join(
        "            {" + json.dumps(name) + ", " + str(value) + "}"
        for name, value in protocol_metadata()["g1_preset_actions"].items()
    )
    return (
        """namespace usdk_clients {
// Keep SDK action/custom-action routes and the preset data-payload route separate.
// Custom action names pass through the SDK JSON serializer.
class G1ArmActionClientCompat final : public unitree::robot::g1::G1ArmActionClient {
public:
    using Base = unitree::robot::g1::G1ArmActionClient;
    using Base::ExecuteAction;
    int32_t ExecuteAction(const std::string& action_name) {
        unitree::common::JsonMap parameter;
        unitree::common::ToJson(action_name, parameter["action_name"]);
        std::string response;
        return Call(unitree::robot::g1::ROBOT_API_ID_ARM_ACTION_EXECUTE_CUSTOM_ACTION,
                    unitree::common::ToJsonString(parameter), response);
    }
    int32_t ExecutePresetAction(int32_t action_id) {
        std::string response;
        const std::string parameter = "{\\"data\\":" + std::to_string(action_id) + "}";
        return Call(unitree::robot::g1::ROBOT_API_ID_ARM_ACTION_EXECUTE_ACTION, parameter, response);
    }
    int32_t ExecutePresetActionByName(const std::string& action_name) {
        static const std::map<std::string, int32_t> actions = {
"""
        + entries
        + """
        };
        const auto found = actions.find(action_name);
        if (found == actions.end()) return usdk::fail("unknown preset arm action name");
        return ExecutePresetAction(found->second);
    }
};
} // namespace usdk_clients
"""
    )


def with_protocol_extensions(clients):
    clients = copy.deepcopy(clients)
    for c in clients:
        extra = {
            ("b2", "sport"): [("FreeEuler", [("bool", "flag", "")])],
            ("r1", "loco"): [
                ("SetTaskId", [("double", "task_id", "")]),
                ("WaveHand", [("bool", "turn_flag", "false")]),
                ("ShakeHand", [("int", "stage", "-1")]),
            ],
            ("g1", "arm"): [
                ("ExecutePresetAction", [("int32_t", "action_id", "")]),
                (
                    "ExecutePresetActionByName",
                    [("const std::string&", "action_name", "")],
                ),
            ],
        }.get((c["robot"], c["service"]), [])
        for name, params in extra:
            c["methods"].append(
                dict(
                    name=name,
                    result="int32_t",
                    binding=snake(name),
                    origin="protocol_extension",
                    params=[
                        dict(type=typ, name=param, default=default, output=False)
                        for typ, param, default in params
                    ],
                )
            )
    return clients


def method_code(c, m):
    prefix = f"usdk_{c['robot']}_{c['service']}_{m['binding']}"
    pars = [(p, info(p, c)) for p in m["params"]]
    outs = [(p, t) for p, t in pars if p["output"]]
    dynamic = any(t["dynamic"] for _, t in outs)
    args = ["usdk_client* client"]
    checks = ["!client", "!client->value"]
    setup, call_args, convert, assign, initialize = [], [], [], [], []
    zig_args = ["self: *@This()"]
    zig_call = ["self.client.handle"]
    zig_setup = []
    for p, t in pars:
        name = snake(p["name"])
        zname = zid(name)
        if p["output"]:
            args.append(t["c"] + "* out_" + name)
            checks.append("!out_" + name)
            initialize.append(f"        if (out_{name}) *out_{name} = {{}};")
            setup.append(f"        {t['cpp']} value_{name}{{}};")
            call_args.append("value_" + name)
            if t["dynamic"]:
                converter = (
                    "meta"
                    if t["kind"] == "meta"
                    else "services"
                    if t.get("inner") == "ServiceState"
                    else "output"
                )
                convert.append(
                    f"        const auto converted_{name} = usdk_clients::{converter}(*owner, std::move(value_{name}));"
                )
                assign.append(f"        *out_{name} = converted_{name};")
            else:
                assign.append(f"        *out_{name} = value_{name};")
            zig_setup.append(
                f"            var out_{name}: {'raw.' + t['c'] if t['dynamic'] else t['z']} = undefined;"
            )
            zig_call.append("&out_" + name)
        elif t["kind"] == "callback":
            args += [f"{t['c']} {name}", "void* context"]
            checks.append("!" + name)
            call_args.append(
                f"[callback={name}, context](const std::string& a, const std::string& b) {{ usdk_clients::config_callback(callback, context, a, b); }}"
            )
            zig_args += [f"{zname}: {t['z']}", "context: ?*anyopaque"]
            zig_call += [zname, "context"]
        else:
            args.append(t["c"] + " " + name)
            zig_args.append(f"{zname}: {t['z']}")
            if t["kind"] == "scalar":
                if t["cpp"] in ("float", "double"):
                    checks.append(f"!std::isfinite({name})")
                call_args.append(name)
                zig_call.append(zname)
            elif t["kind"] == "enum":
                checks.append(f"({name} < 0 || {name} > 2)")
                call_args.append(f"static_cast<{t['cpp']}>({name})")
                zig_call.append(f"@backingInt({zname})")
            elif t["kind"] == "string":
                call_args.append(f"usdk::string({name})")
                zig_call.append(f"string({zname})")
            elif t["kind"] == "vector":
                setup.append(
                    f"        auto value_{name} = usdk_clients::copy({name}.data, {name}.len);"
                )
                if t["inner"] == "float":
                    setup.append(
                        f'        for (const auto value : value_{name}) if (!std::isfinite(value)) return usdk::fail("nonfinite client sequence value");'
                    )
                call_args.append("value_" + name)
                zig_call.append(f".{{ .data = {zname}.ptr, .len = {zname}.len }}")
            elif t["kind"] == "path":
                setup += [
                    f'        if ({name}.len && !{name}.data) return usdk::fail("null path");',
                    f"        usdk_clients::check_length<{t['cpp']}::value_type>({name}.len);",
                    f"        {t['cpp']} value_{name};",
                    f"        value_{name}.reserve({name}.len);",
                    f"        for (size_t i = 0; i < {name}.len; ++i) {{",
                    f"            const auto& p = {name}.data[i];",
                ]
                fields = (
                    "p.t_from_start, p.x, p.y, p.yaw"
                    if c["robot"] == "a2"
                    else "p.time_from_start, p.x, p.y, p.yaw, p.vx, p.vy, p.vyaw"
                )
                finite = " || ".join(
                    f"!std::isfinite({field})" for field in fields.split(", ")
                )
                setup += [
                    f'            if ({finite}) return usdk::fail("nonfinite path value");',
                    f"            value_{name}.push_back({{{fields}}});",
                    "        }",
                ]
                call_args.append("value_" + name)
                zig_call.append(f".{{ .data = {zname}.ptr, .len = {zname}.len }}")
            else:
                raise ValueError(t)
    if dynamic:
        args.append("usdk_client_output** out_owner")
        checks.append("!out_owner")
        setup.insert(0, "        auto owner = std::make_unique<usdk_client_output>();")
        zig_setup.append("            var owner: ?*raw.usdk_client_output = null;")
        zig_call.append("&owner")
        initialize.append("        if (out_owner) *out_owner = nullptr;")
        assign.append("        *out_owner = owner.release();")
    signature = "int32_t " + prefix + "(" + ", ".join(args) + ")"
    cpp = (
        [signature + " {", "    return usdk::guard([&]() -> int32_t {"]
        + initialize
        + [
            "        if ("
            + " || ".join(checks)
            + ') return usdk::fail("invalid client method argument");',
            f"        auto* typed = dynamic_cast<{implementation(c)}*>(client->value.get());",
            '        if (!typed) return usdk::fail("wrong client type");',
        ]
    )
    cpp += setup
    call = f"typed->{m['name']}(" + ", ".join(call_args) + ")"
    if m["result"] == "void":
        cpp.append("        " + call + ";")
    else:
        cpp += [
            "        const int32_t status = " + call + ";",
            "        if (status != 0) return status;",
        ]
    cpp += convert + assign + ["        return 0;", "    });", "}"]
    result_name = "".join(p.title() for p in m["binding"].split("_")) + "Result"
    if len(outs) > 1:
        ret = result_name
        zig = [f"        pub const {result_name} = struct {{"]
        for p, t in outs:
            zig.append(f"            {zid(snake(p['name']))}: {t['z']},")
        zig.append("        };")
    else:
        ret = outs[0][1]["z"] if outs else "void"
        zig = []
    return_type = "Owned(" + ret + ")" if dynamic else ret
    defaults = ", ".join(
        f"{snake(p['name'])} = {p['default']}" for p, _ in pars if p["default"]
    )
    extension_docs = {
        "FreeEuler": "Enables or disables free Euler motion.",
        "SetTaskId": "Selects an arm task using its numeric task ID.",
        "WaveHand": "Starts a waving task, optionally with a turn.",
        "ShakeHand": "Selects a handshake stage; other values alternate stages.",
        "ExecutePresetAction": "Executes a preset arm action using the data-payload protocol.",
        "ExecutePresetActionByName": "Looks up a name in constants.g1.arm.preset_actions and executes that preset.",
    }
    description = (
        extension_docs[m["name"]]
        if m.get("origin") == "protocol_extension"
        else f"Upstream SDK: {m['name']}."
    )
    zig.append(
        f"        /// {description}" + (f" Defaults: {defaults}." if defaults else "")
    )
    if c["service"] == "audio" and m["name"] == "PlayStop":
        zig.append(
            "        /// Returns the actual RPC error; the pinned upstream method discards it."
        )
    if (c["robot"], c["service"], m["binding"]) == (
        "g1",
        "arm",
        "execute_action_by_name",
    ):
        zig.append(
            "        /// Custom action names are JSON-escaped; the API and action_name key are unchanged."
        )
    zig.append(
        f"        pub fn {zid(camel(m['binding']))}("
        + ", ".join(zig_args)
        + f") !{return_type} {{"
    )
    zig += zig_setup
    zig.append(
        "            try core.check(raw." + prefix + "(" + ", ".join(zig_call) + "));"
    )

    def out_expr(p, t):
        x = "out_" + snake(p["name"])
        if t["kind"] == "string":
            return f"stringSlice({x})"
        if t["kind"] in ("vector", "map"):
            return f"slice({t['z'].removeprefix('[]const ')}, {x})"
        return x

    if outs:
        val = (
            out_expr(*outs[0])
            if len(outs) == 1
            else ".{ "
            + ", ".join(
                "." + zid(snake(p["name"])) + " = " + out_expr(p, t) for p, t in outs
            )
            + " }"
        )
        zig.append(
            "            return "
            + (".{ .value = " + val + ", .owner = owner }" if dynamic else val)
            + ";"
        )
    zig.append("        }")
    return signature + ";", "\n".join(cpp), "\n".join(zig)


def generate_constants():
    lines = [
        "//! SDK identifiers, versions, errors, arm action names, and additional protocol variants.",
        "//! Generated by scripts/generate_clients.py; do not edit.",
    ]
    lines.append("pub const internal = struct {")
    for p in sorted((SDK / "unitree/robot/internal").glob("*.hpp"), key=lambda p: p.as_posix()):
        text = strip_comments(p.read_text(encoding="utf-8"))
        for name, value in re.findall(
            r"\bconst\s+int32_t\s+(\w+)\s*=\s*(-?\d+)\s*;", text
        ):
            lines.append(f"    pub const {snake(name)} = {value};")
        for name, value in re.findall(r"UT_DECL_ERR\(\s*(\w+)\s*,\s*(\d+)\s*,", text):
            lines.append(f"    pub const {snake(name)} = {value};")
    lines.append("};")
    for robot in sorted(ROBOTS):
        lines.append(f"pub const {robot} = struct {{")
        for directory in sorted((SDK / "unitree/robot" / robot).iterdir(), key=lambda p: p.as_posix()):
            if not directory.is_dir():
                continue
            vals = {}
            for p in sorted(directory.glob("*.hpp"), key=lambda p: p.as_posix()):
                text = strip_comments(p.read_text(encoding="utf-8"))
                for m in re.finditer(
                    r'\bconst\s+(?:std::string|int32_t|int|uint32_t|float)\s+(\w+)\s*=\s*("[^"\n]*"|[-+]?\d+(?:\.\d+)?[fF]?)\s*;',
                    text,
                ):
                    vals[m[1]] = m[2].rstrip("fF") if not m[2].startswith('"') else m[2]
                for m in re.finditer(r"UT_DECL_ERR\(\s*(\w+)\s*,\s*(\d+)\s*,", text):
                    vals[m[1]] = m[2]
            if not vals and directory.name != "arm":
                continue
            if robot == "r1" and directory.name == "loco":
                vals["ROBOT_API_ID_LOCO_SET_ARM_TASK"] = "7106"
            lines.append(f"    pub const {zid(directory.name)} = struct {{")
            for name, val in sorted(vals.items()):
                lines.append(f"        pub const {snake(name)} = {val};")
            if directory.name == "arm":
                action = next(directory.glob("*client.hpp")).read_text(encoding="utf-8")
                pos = action.find("action_map =")
                body, _ = block(action, action.index("{", pos))
                lines.append(
                    "        pub const actions = [_]struct { name: []const u8, id: i32 }{"
                )
                for name, val in re.findall(r'\{\s*"([^"]+)"\s*,\s*(\d+)\s*\}', body):
                    lines.append(f'            .{{ .name = "{name}", .id = {val} }},')
                lines.append("        };")
                if robot == "g1":
                    lines.append(
                        "        /// Names for executePresetActionByName; right kiss uses 13 (actions uses 12)."
                    )
                    lines.append(
                        "        pub const preset_actions = [_]struct { name: []const u8, id: i32 }{"
                    )
                    for name, value in protocol_metadata()["g1_preset_actions"].items():
                        lines.append(
                            f"            .{{ .name = {json.dumps(name)}, .id = {value} }},"
                        )
                    lines.append("        };")
            lines.append("    };")
        lines.append("};")
    lines.append(
        "/// Additional protocol metadata for generic RPC; typed clients retain the SDK defaults."
    )
    lines.append("pub const protocol_variants = struct {")
    by_robot = protocol_metadata()["protocol_variants"]
    for robot, services in sorted(by_robot.items()):
        lines.append(f"    pub const {robot} = struct {{")
        for service, values in sorted(services.items()):
            lines.append(f"        pub const {service} = struct {{")
            for name, value in sorted(values.items()):
                lines.append(f"            pub const {snake(name)} = {json.dumps(value)};")
            lines.append("        };")
        lines.append("    };")
    lines.append("};")
    return "\n".join(lines) + "\n"


def generate(clients):
    files = {}
    method_docs = []
    cpp_method_count = sum(len(c["methods"]) for c in clients)
    clients = with_protocol_extensions(clients)
    header = [HEADER]
    zig = [ZIG_HEADER]
    conformance = [
        "//! Generated by scripts/generate_clients.py; do not edit.",
        'const sdk = @import("unitree_sdk2");',
        "pub fn check() void {",
    ]
    doc = [
        "# 客户端 API",
        "",
        "<!-- Generated by scripts/generate_clients.py; do not edit. -->",
        "",
        "客户端通过 C ABI 调用官方 C++ SDK。协议扩展使用同一套原生 RPC 通道；动作表和附加常量随本库提供。",
        "",
        "通过 `sdk.<型号>.<客户端>` 创建客户端，例如 `sdk.go2.SportClient`。初始化和释放示例见[使用指南](usage.zh-CN.md#机器人客户端)。所有输入参数均需显式传入。",
        "",
        "动态输出返回 `Owned(T)`，通过 `.value` 访问结果，并使用 `defer result.deinit()` 释放；其切片和嵌套字符串在释放后失效。输入切片仅在调用期间借用。多个输出字段组成该客户端下的 `*Result` 类型。",
        "",
        "同一客户端由调用方串行使用。配置变化回调由 SDK 线程调用，回调上下文需持续有效到客户端销毁；回调内不得销毁客户端。",
        "",
        "| 产品 | 类 | 方法（不含 Init） |",
        "|---|---|---:|",
    ]
    current_robot = None
    for c in clients:
        if current_robot != c["robot"]:
            if current_robot is not None:
                zig.append("};")
            current_robot = c["robot"]
            zig.append(f"pub const {current_robot} = struct {{")
            if current_robot in ("a2", "b2"):
                zig.append(
                    f"    pub const PathPoint = raw.usdk_client_{current_robot}_path_point;"
                )
        robot, service, cls = c["robot"], c["service"], c["cls"]
        cpp = [
            "// Generated by scripts/generate_clients.py; do not edit.",
            '#include "clients_internal.hpp"',
            f"#include <{c['header']}>",
            "",
        ]
        if service == "audio":
            cpp.append(audio_extension(c))
        if (robot, service) in PROTOCOL_EXTENSIONS:
            cpp.append(PROTOCOL_EXTENSIONS[(robot, service)])
        if (robot, service) == ("g1", "arm"):
            cpp.append(g1_arm_extension())
        create = f"usdk_{robot}_{service}_create"
        ctor_args = "bool enable_lease, " if c["lease"] else ""
        header.append(f"int32_t {create}({ctor_args}usdk_client** out_client);")
        cpp += [
            f"int32_t {create}({ctor_args}usdk_client** out_client) {{",
            "    return usdk::guard([&]() -> int32_t {",
            '        if (!out_client) return usdk::fail("null client output");',
            "        *out_client = nullptr;",
            "        usdk::require_channel();",
            "        auto client = std::make_unique<usdk_client>();",
            f"        auto typed = std::make_unique<{implementation(c)}>({'enable_lease' if c['lease'] else ''});",
            "        typed->Init();",
            "        client->value = std::move(typed);",
            "        *out_client = client.release();",
            "        return 0;",
            "    });",
            "}",
            "",
        ]
        public_cls = "ArmActionClient" if service == "arm" else cls
        zig += [
            f"    pub const {public_cls} = struct {{",
            "        client: core.Client,",
            f"        pub fn init({'enable_lease: bool' if c['lease'] else ''}) !@This() {{",
            "            var handle: ?*raw.usdk_client = null;",
            f"            try core.check(raw.{create}({'enable_lease, ' if c['lease'] else ''}&handle));",
            "            return .{ .client = .{ .handle = handle.? } };",
            "        }",
            "        pub fn deinit(self: *@This()) void { self.client.deinit(); }",
            "        pub fn setTimeout(self: *@This(), seconds: f32) !void { try self.client.setTimeout(seconds); }",
        ]
        for m in c["methods"]:
            h, cc, z = method_code(c, m)
            header.append(h)
            cpp += [cc, ""]
            zig.append(z)
            declaration = next(
                line.strip().removeprefix("pub fn ").removesuffix(" {")
                for line in z.splitlines()
                if line.strip().startswith("pub fn ")
            )
            declaration = declaration.replace("self: *@This(), ", "").replace(
                "self: *@This()", ""
            )
            method_docs.append((f"{robot}.{public_cls}", declaration))
        if robot == "go2" and service == "sport":
            zig += [
                "        pub fn autoRecoverySet(self: *@This(), flag: bool) !void { try self.autoRecoverSet(flag); }",
                "        pub fn autoRecoveryGet(self: *@This()) !bool { return self.autoRecoverGet(); }",
            ]
        if robot == "g1" and service == "loco":
            for name, val in [
                ("squat2StandUp", 706),
                ("lie2StandUp", 702),
                ("standUp2Squat", 706),
            ]:
                zig.append(
                    f"        pub fn {name}(self: *@This()) !void {{ try self.setFsmId({val}); }}"
                )
            zig.append(
                "        pub fn balanceStandMode(self: *@This(), balance_mode: i32) !void { try self.setBalanceMode(balance_mode); }"
            )
        if robot == "r1" and service == "loco":
            for name, val in [
                ("stance", 4),
                ("lie2StandUp", 701),
                ("standUp2Lie", 702),
            ]:
                zig.append(
                    f"        pub fn {name}(self: *@This()) !void {{ try self.setFsmId({val}); }}"
                )
        zig.append("    };")
        if public_cls != cls:
            zig.append(f"    pub const {cls} = {public_cls};")
        if robot == "b2" and service == "sport":
            zig.append("    pub const VuiClient = go2.VuiClient;")
        for name in ["init", "deinit", "setTimeout"] + [
            camel(m["binding"]) for m in c["methods"]
        ]:
            conformance.append(f"    _ = &sdk.clients.{robot}.{public_cls}.{name};")
        files[f"src/cpp/generated/clients_{robot}_{service}.cpp"] = (
            "\n".join(cpp) + "\n"
        )
        doc.append(f"| {robot} | {public_cls} | {len(c['methods'])} |")
    zig.append("};")
    zig.append(
        "pub const comm = struct { pub const MotionSwitcherClient = b2.MotionSwitcherClient; };"
    )
    header += ["#ifdef __cplusplus", "}", "#endif", "#endif"]
    files["include/usdk_clients.h"] = "\n".join(header) + "\n"
    files["src/cpp/generated/clients_internal.hpp"] = HELPERS
    files["src/cpp/generated/clients_support.cpp"] = (
        '// Generated by scripts/generate_clients.py; do not edit.\n#include "clients_internal.hpp"\nextern "C" void usdk_client_output_destroy(usdk_client_output* owner) { delete owner; }\n'
    )
    files["src/clients.zig"] = "\n".join(zig) + "\n"
    files["src/constants.zig"] = generate_constants()
    doc += [
        "",
        f"总计：{len(clients)} 个机器人客户端，{cpp_method_count} 个官方 SDK 方法，{sum(len(c['methods']) for c in clients) - cpp_method_count} 个协议扩展方法，另含便利别名。应用通过 Zig 接口使用这些能力。",
        "",
        "C ABI 保留上游状态码；Zig 方法通过 `core.check` 转为错误。需要精确状态码时调用 `raw.usdk_*` 或读取核心错误信息。重载使用 `moveWithMode`、`executeActionByName`、`metaJson` 区分。",
        "",
        "便利接口：B2 `freeEuler`；R1 `setTaskId`、`waveHand`、`shakeHand`。这些方法通过同一客户端发送请求，沿用其超时与租约。R1 `setTaskId` 使用 `f64` 接收任务数值。便利别名包括 B2 Vui、Go2 AutoRecovery、G1/R1 起立动作；G1 带模式的平衡站立对应 `balanceStandMode`。",
        "",
        "G1 手臂接口按用途区分：`executeAction` 通过 API 7106 发送 `{action_id: id}`；`executePresetAction` 通过同一 API 发送 `{data: id}`，用于预设动作协议。`executePresetActionByName` 在 `constants.g1.arm.preset_actions` 中查找名称后调用预设动作接口，未知名称返回 `InvalidArgument`。`executeActionByName` 用于执行自定义教学动作，通过 API 7108 发送 `{action_name: name}`。两套动作表各自保留协议值：`preset_actions` 的 right kiss 为 13，`actions` 中为 12；它们不能互换。",
    ]
    doc += [
        "",
        "`constants.<产品>.<服务>` 提供官方 SDK 常量，类型化客户端使用这些版本号。`constants.protocol_variants.<产品>.<服务>` 提供额外协议元数据，供通用 RPC 显式选择：Go2 Video/Vui 和 B2 Vui 的版本可为 1.0.0.1（默认 1.0.0.0），Go2/B2 Sport 的 server-not-init 错误可为 4202（默认 4205）。这些值不自动替换客户端默认配置；需要时将版本号传给 `core.Client.init`，再通过 `registerApi` 注册并调用对应接口。",
        "",
        "浮点 RPC 输入（含路径和浮点数组）必须是有限数；DDS 数据字段保留原始浮点值。`AudioClient.playStop` 返回实际 RPC 状态。G1 `executeActionByName` 支持名称中的引号、反斜杠和控制字符。",
        "",
        "## 方法签名",
        "",
        "以下是 Zig 方法签名，省略实例参数 `self`。`!T` 表示成功时返回 `T`，失败时返回错误。输入字符串和数组使用切片。",
        "",
        "| 客户端 | 方法签名 |",
        "|---|---|",
    ]
    for client, declaration in method_docs:
        doc.append(f"| `{client}` | `{declaration}` |")
    files["docs/clients.md"] = "\n".join(doc) + "\n"
    conformance.append("}")
    files["tests/compile/generated_client_check.zig"] = "\n".join(conformance) + "\n"
    return files


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--inventory", action="store_true")
    parser.add_argument(
        "--sdk", type=Path, required=True, help="SDK directory resolved by Zig"
    )
    parser.add_argument("--zig-exe", default="zig", help="Zig executable used to format generated code")
    args = parser.parse_args()
    global SDK
    SDK = args.sdk.resolve() / "include"
    clients = parse()
    if args.inventory:
        print(json.dumps(clients, indent=2))
        return
    files = generate(clients)
    failed = []
    for name, content in files.items():
        if name.endswith(".zig"):
            result = subprocess.run(
                [args.zig_exe, "fmt", "--stdin"], input=content, text=True, encoding="utf-8", capture_output=True
            )
            if result.returncode:
                raise RuntimeError(result.stderr)
            content = result.stdout
        target = ROOT / name
        if args.check:
            if not target.exists() or target.read_text(encoding="utf-8") != content:
                failed.append(name)
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(content, encoding="utf-8", newline="\n")
    if failed:
        raise SystemExit("Generated files are out of date: " + ", ".join(failed))
    print(
        f"{len(clients)} clients, {sum(len(c['methods']) for c in clients)} methods, {len(files)} files "
        + ("verified" if args.check else "generated")
    )


if __name__ == "__main__":
    main()

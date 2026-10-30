#!/usr/bin/env python3
"""独立核对上游接口与实际绑定的路由、签名、字段、常量和适配说明。

审查变更后使用 --write 更新 tests/reference/coverage.json；默认检查实现及报告一致性。
本工具提供源码覆盖证据，不代表已验证机器人硬件或固件执行结果。
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

import audit_upstream as audit
import generate_clients as clients_generator
import generate_messages as messages_generator
from generated_files import check_or_write

ROOT = Path(__file__).resolve().parents[1]
# Convenience routes are checked separately from official SDK methods.
CONVENIENCE_ALIASES = {
    ("go2/sport", "AutoRecoverySet"): (
        "autoRecoverySet",
        "self.autoRecoverSet(flag)",
        "C++ spells this AutoRecoverSet",
    ),
    ("go2/sport", "AutoRecoveryGet"): (
        "autoRecoveryGet",
        "self.autoRecoverGet()",
        "C++ spells this AutoRecoverGet",
    ),
    ("g1/loco", "Squat2StandUp"): (
        "squat2StandUp",
        "self.setFsmId(706)",
        "Uses FSM 706",
    ),
    ("g1/loco", "Lie2StandUp"): (
        "lie2StandUp",
        "self.setFsmId(702)",
        "Uses FSM 702",
    ),
    ("g1/loco", "StandUp2Squat"): (
        "standUp2Squat",
        "self.setFsmId(706)",
        "Shares FSM 706 with squat2StandUp",
    ),
    ("g1/loco", "BalanceStand"): (
        "balanceStandMode",
        "self.setBalanceMode(balance_mode)",
        "Explicit balance mode; C++ BalanceStand() fixes mode 0",
    ),
    ("r1/loco", "Stance"): (
        "stance",
        "self.setFsmId(4)",
        "Uses FSM 4",
    ),
    ("r1/loco", "Lie2StandUp"): (
        "lie2StandUp",
        "self.setFsmId(701)",
        "Uses FSM 701",
    ),
    ("r1/loco", "StandUp2Lie"): (
        "standUp2Lie",
        "self.setFsmId(702)",
        "Uses FSM 702",
    ),
}


def compact(source: str) -> str:
    """Ignore formatting, but preserve quoted payload strings verbatim."""
    tokens = re.split(r'("(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\')', source)
    return "".join(
        token if token.startswith(('"', "'")) else re.sub(r"\s+", "", token)
        for token in tokens
    )


def digest(source: str) -> str:
    return hashlib.sha256(source.encode("utf-8")).hexdigest()


def clean(source: str) -> str:
    return audit.scrub_cpp(source)


def delimited(source: str, start: int, opening="{", closing="}") -> int:
    depth = 0
    for index in range(start, len(source)):
        if source[index] == opening:
            depth += 1
        elif source[index] == closing:
            depth -= 1
            if not depth:
                return index
    raise ValueError(f"Unbalanced {opening}{closing}")


def scope(source: str, name: str, kind="struct") -> str:
    pattern = rf"\bpub\s+const\s+{re.escape(name)}\s*=\s*{kind}(?:\([^)]*\))?\s*\{{"
    sanitized = clean(source)
    match = re.search(pattern, sanitized)
    if not match:
        raise ValueError(f"Missing Zig {kind} {name}")
    return source[match.end() : delimited(sanitized, match.end() - 1)]


def zig_scope(source: str, names: list[str]) -> str:
    for name in names:
        source = scope(source, name)
    return source


def function(source: str, name: str, zig=False) -> str:
    sanitized = clean(source)
    prefix = r"\bpub\s+fn\s+" if zig else r"\b"
    match = re.search(prefix + re.escape(name) + r"\s*\(", sanitized)
    if not match:
        raise ValueError(f"Missing {'Zig' if zig else 'native'} function {name}")
    close = delimited(sanitized, match.end() - 1, "(", ")")
    start = sanitized.find("{", close)
    while start >= 0 and re.search(r"\berror\s*$", sanitized[close:start]):
        close = delimited(sanitized, start)
        start = sanitized.find("{", close)
    if start < 0:
        raise ValueError(f"Function has no implementation: {name}")
    return source[match.start() : delimited(sanitized, start) + 1]


def split_parameters(text: str) -> list[str]:
    result, start, depth = [], 0, 0
    for index, char in enumerate(text):
        if char in "<([{":
            depth += 1
        elif char in ">)]}":
            depth -= 1
        elif char == "," and depth == 0:
            result.append(text[start:index].strip())
            start = index + 1
    if text[start:].strip():
        result.append(text[start:].strip())
    return result


def canonical_parameters(text: str) -> list[tuple[str, str]]:
    result = []
    for parameter in split_parameters(text):
        declaration, _, default = parameter.partition("=")
        declaration = declaration.strip()
        match = re.search(r"\b([A-Za-z_]\w*)\s*$", declaration)
        if match and match.start() > 0 and declaration[match.start() - 1] != ":":
            declaration = declaration[: match.start()].strip()
        result.append((re.sub(r"\s+", "", declaration), re.sub(r"\s+", "", default)))
    return result


class Checks:
    def __init__(self, root: Path):
        self.root = root
        self.errors: list[str] = []
        self.files: dict[str, str] = {}

    def read(self, relative: str) -> str:
        if relative not in self.files:
            path = self.root / relative
            if not path.is_file():
                self.errors.append(f"Missing artifact: {relative}")
                self.files[relative] = ""
            else:
                self.files[relative] = path.read_text(encoding="utf-8")
        return self.files[relative]

    def require(self, condition: bool, message: str):
        if not condition:
            self.errors.append(message)

    def implementation(
        self, relative: str, name: str, zig=False, required: str | None = None
    ) -> str:
        try:
            body = function(self.read(relative), name, zig)
        except ValueError as exc:
            self.errors.append(f"{relative}: {exc}")
            return ""
        if required:
            self.require(
                compact(required) in compact(body),
                f"Wrong binding route in {relative}:{name}: expected {required}",
            )
        return body


def check_clients(
    checks: Checks, upstream: dict, cpp_root: Path
) -> tuple[list, list, list]:
    clients_generator.SDK = cpp_root / "include"
    cpp_metadata = clients_generator.parse()
    metadata = clients_generator.with_protocol_extensions(cpp_metadata)
    by_namespace = {f"{c['robot']}/{c['service']}": c for c in metadata}
    cpp_by_namespace = {f"{c['robot']}/{c['service']}": c for c in cpp_metadata}
    zig_source = checks.read("src/clients.zig")
    header = checks.read("include/usdk_clients.h")
    scopes = {}
    verified = {}
    for namespace, client in by_namespace.items():
        public_class = (
            "ArmActionClient" if client["service"] == "arm" else client["cls"]
        )
        try:
            scopes[namespace] = zig_scope(zig_source, [client["robot"], public_class])
        except ValueError as exc:
            checks.errors.append(str(exc))
            scopes[namespace] = ""
        cpp_file = (
            f"src/cpp/generated/clients_{client['robot']}_{client['service']}.cpp"
        )
        cpp_source = checks.read(cpp_file)
        create = f"usdk_{client['robot']}_{client['service']}_create"
        init = (
            function(scopes[namespace], "init", zig=True) if scopes[namespace] else ""
        )
        checks.require(create in header, f"Missing constructor declaration {create}")
        checks.require(f"raw.{create}(" in init, f"Zig init does not call {create}")
        checks.implementation(cpp_file, create, required="typed->Init();")
        verified[(namespace, "Init", ())] = {
            "zig": f"clients.{client['robot']}.{public_class}.init",
            "c_symbol": create,
            "native_source": cpp_file,
            "adaptation": "Construction and upstream Init are one owning Zig init operation",
        }
        for method in client["methods"]:
            name = clients_generator.camel(method["binding"])
            c_symbol = f"usdk_{client['robot']}_{client['service']}_{method['binding']}"
            expected_header, expected_cpp, expected_zig = clients_generator.method_code(
                client, method
            )
            checks.require(
                expected_header in header,
                f"Missing or changed C ABI signature: {c_symbol}",
            )
            actual_cpp = checks.implementation(cpp_file, c_symbol)
            checks.require(
                compact(actual_cpp) == compact(function(expected_cpp, c_symbol)),
                f"Native implementation diverges from checked metadata: {c_symbol}",
            )
            try:
                actual_zig = function(scopes[namespace], name, zig=True)
                expected_fn = function(expected_zig, name, zig=True)
                checks.require(
                    compact(actual_zig) == compact(expected_fn),
                    f"Zig implementation diverges from checked metadata: {namespace}.{name}",
                )
            except ValueError as exc:
                checks.errors.append(f"src/clients.zig:{namespace}: {exc}")
            signature = tuple(
                (re.sub(r"\s+", "", p["type"]), re.sub(r"\s+", "", p["default"]))
                for p in method["params"]
            )
            key = (namespace, method["name"], signature)
            checks.require(key not in verified, f"Duplicate binding metadata: {key}")
            verified[key] = {
                "zig": f"clients.{client['robot']}.{public_class}.{name}",
                "c_symbol": c_symbol,
                "native_source": cpp_file,
                "origin": method.get("origin", "C++"),
                "parameters": method["params"],
            }
            if namespace == "g1/arm" and method["binding"] == "execute_action_by_name":
                adapter = checks.implementation(
                    cpp_file,
                    "ExecuteAction",
                    required='unitree::common::ToJson(action_name, parameter["action_name"]);',
                )
                checks.require(
                    compact("using Base::ExecuteAction;") in compact(cpp_source),
                    "G1 custom-action adapter hides the numeric ExecuteAction overload",
                )
                checks.require(
                    compact(
                        "Call(unitree::robot::g1::ROBOT_API_ID_ARM_ACTION_EXECUTE_CUSTOM_ACTION, unitree::common::ToJsonString(parameter), response)"
                    )
                    in compact(adapter),
                    "G1 custom-action adapter changed its API or bypasses JSON serialization",
                )
                verified[key]["adaptation"] = (
                    "Custom action names use the official JSON serializer instead of raw string concatenation; API 7108 and action_name are preserved, including quotes, backslashes and control characters. Numeric ExecuteAction remains inherited with API 7106/action_id."
                )
                verified[key]["native_adapter_sha256"] = digest(compact(adapter))
    records = []
    audited_keys = set()
    for client in upstream["cpp_clients"]:
        namespace = client["namespace"]
        checks.require(
            namespace in cpp_by_namespace, f"Client missing from generator: {namespace}"
        )
        for method in client["methods"]:
            signature = tuple(canonical_parameters(method["parameters"]))
            key = (namespace, method["name"], signature)
            audited_keys.add(key)
            target = verified.get(key)
            checks.require(
                target is not None, f"C++ method is unbound: {method['key']}"
            )
            if target:
                records.append(
                    {"upstream": method["key"], "source": client["source"], **target}
                )
    generated_cpp_keys = {
        key for key, value in verified.items() if value.get("origin", "C++") == "C++"
    }
    checks.require(
        audited_keys == generated_cpp_keys,
        "Independent C++ audit and binding metadata disagree on overloads/defaults",
    )

    extensions = []
    for (namespace, name, _), target in verified.items():
        if target.get("origin") != "protocol_extension":
            continue
        adapter = checks.implementation(target["native_source"], name)
        extensions.append(
            {
                **target,
                "method": name,
                "native_adapter_sha256": digest(compact(adapter)),
            }
        )
    # Verify the supplemental request bodies, registrations and preset lookup.
    for (robot, service), expected in clients_generator.PROTOCOL_EXTENSIONS.items():
        relative = f"src/cpp/generated/clients_{robot}_{service}.cpp"
        checks.require(
            compact(expected) in compact(checks.read(relative)),
            f"Supplemental protocol adapter changed: {robot}/{service}",
        )
    checks.require(
        compact(clients_generator.g1_arm_extension())
        in compact(checks.read("src/cpp/generated/clients_g1_arm.cpp")),
        "G1 preset action adapter differs from protocol metadata",
    )
    aliases = []
    for (namespace, _), (binding, route, note) in CONVENIENCE_ALIASES.items():
        try:
            body = function(scopes[namespace], binding, zig=True)
            checks.require(
                compact(route) in compact(body),
                f"Convenience alias has wrong route: {namespace}.{binding}",
            )
        except ValueError as exc:
            checks.errors.append(str(exc))
        client = by_namespace[namespace]
        aliases.append(
            {
                "zig": f"clients.{client['robot']}.{client['cls']}.{binding}",
                "route": route,
                "behavior": note,
            }
        )
    for namespace, declaration, target in (
        ("b2", "pub const VuiClient = go2.VuiClient;", "go2.VuiClient"),
        (
            None,
            "pub const MotionSwitcherClient = b2.MotionSwitcherClient;",
            "b2.MotionSwitcherClient",
        ),
    ):
        body = scope(zig_source, namespace) if namespace else zig_source
        checks.require(declaration in body, f"Missing client alias: {declaration}")
        name = declaration.split()[2]
        aliases.append(
            {
                "zig": "clients." + (namespace + "." if namespace else "") + name,
                "route": "clients." + target,
            }
        )
    return records, extensions, aliases


def check_messages(checks: Checks, upstream: dict, cpp_root: Path) -> list:
    metadata = messages_generator.parse(cpp_root)
    actual_types = {
        message.cpp.removeprefix("::").replace("::", "."): message
        for message in metadata
    }
    expected_types = set(upstream["messages"])
    checks.require(
        set(actual_types) == expected_types,
        "DDS type inventory differs between independent audit and generator",
    )
    # Also validate every accessor independently of the generator's private-field parser.
    records = []
    for canonical, message in sorted(actual_types.items()):
        source = (cpp_root / "include" / message.header).read_text(encoding="utf-8")
        accessor_fields = []
        for match in re.finditer(
            r"([^\n{};]+?)\s+(\w+)\(\)\s+const\s*\{\s*return this->\2_;\s*\}", source
        ):
            typ = match[1].strip().removeprefix("const ").removesuffix("&").strip()
            accessor_fields.append((re.sub(r"\s+", "", typ), match[2]))
        fields = [(re.sub(r"\s+", "", t), n) for t, n in message.fields]
        checks.require(
            fields == accessor_fields,
            f"DDS fields/accessors disagree or fields were omitted: {canonical}",
        )
        records.append(
            {
                "upstream": canonical,
                "source": "include/" + message.header,
                "zig": f"messages.{message.group}.{message.name}",
                "c_type": message.c,
                "type_id": message.type_id,
                "fields": [{"type": t, "name": n} for t, n in message.fields],
            }
        )
    for relative, expected in messages_generator.outputs(metadata).items():
        if relative.startswith(("src/", "include/")):
            checks.require(
                checks.read(relative) == expected,
                f"DDS generated artifact is missing/stale/modified: {relative}",
            )
    return records


def zig_literal(checks: Checks, file: str, names: list[str], constant: str):
    try:
        source = zig_scope(checks.read(file), names)
    except ValueError as exc:
        checks.errors.append(f"{file}: {exc}")
        return None
    match = re.search(
        rf'\bpub\s+const\s+{re.escape(constant)}(?:\s*:\s*[^=;]+)?\s*=\s*("[^"]*"|[-+]?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?)\s*;',
        source,
    )
    if not match:
        checks.errors.append(
            f"Missing Zig constant {file}:{'.'.join(names + [constant])}"
        )
        return None
    return json.loads(match[1])


def check_constants(checks: Checks, upstream: dict) -> dict:
    records = []
    for constant in upstream["constants"]:
        parts = constant["source"].split("/")
        names = ["internal"] if parts[0] == "internal" else parts[:2]
        name = clients_generator.snake(constant["name"])
        value = zig_literal(checks, "src/constants.zig", names, name)
        checks.require(
            value == constant["value"],
            f"C++ constant changed: {constant['source']}:{constant['name']}",
        )
        records.append({**constant, "zig": "constants." + ".".join(names + [name])})
    variants = []
    for robot, services in clients_generator.protocol_metadata()[
        "protocol_variants"
    ].items():
        for service, constants in services.items():
            names = ["protocol_variants", robot, service]
            for name, expected in constants.items():
                binding = clients_generator.snake(name)
                value = zig_literal(checks, "src/constants.zig", names, binding)
                checks.require(
                    value == expected,
                    f"Protocol constant changed: {robot}/{service}/{name}",
                )
                variants.append(
                    {
                        "source": "scripts/protocol_extensions.json",
                        "name": name,
                        "value": expected,
                        "zig": "constants." + ".".join(names + [binding]),
                    }
                )
    return {"cpp": records, "protocol_variants": variants}


def enum_values(source: str, name: str) -> dict[str, int]:
    body = scope(source, name, "enum")
    result, current = {}, -1
    for part in clean(body).split(","):
        match = re.fullmatch(r"\s*(\w+)\s*(?:=\s*(0x[0-9a-fA-F]+|\d+))?\s*", part)
        if match:
            current = int(match[2], 0) if match[2] else current + 1
            result[match[1]] = current
    return result


def check_helpers(checks: Checks, upstream: dict, cpp_root: Path) -> dict:
    robots = checks.read("src/robots.zig")
    remote = checks.read("src/remote_control.zig")
    constants = checks.read("src/constants.zig")
    rows, enum_rows, arrays, actions = [], [], [], []

    def expect_function(file: str, name: str) -> str:
        checks.implementation(file, name, zig=True)
        return file.removeprefix("src/").removesuffix(".zig") + "." + name

    def model_name(name: str) -> str:
        replacements = {
            "FR_": "front_right_",
            "FL_": "front_left_",
            "RR_": "rear_right_",
            "RL_": "rear_left_",
        }
        for prefix, replacement in replacements.items():
            if name.startswith(prefix):
                return replacement + name[len(prefix) :].lower()
        return clients_generator.snake(name)

    # Joint enums are checked value-for-value, not by a declaration-name search.
    for header in upstream["dds_wrappers"]:
        parts = header["source"].split("/")
        for enum in header["enums"]:
            robot = parts[1]
            target = "robots." + robot + "." + enum["name"]
            enum_source = (
                scope(remote, "low_level") if robot == "go2" else scope(robots, robot)
            )
            actual = enum_values(
                enum_source, "Go2Joint" if robot == "go2" else enum["name"]
            )
            expected = {
                model_name(name): value for name, value in enum["values"].items()
            }
            checks.require(
                actual == expected,
                f"Model enum values changed: {header['source']}:{enum['name']}",
            )
            enum_rows.append(
                {
                    "source": header["source"],
                    "upstream": enum["name"],
                    "zig": target,
                    "values": actual,
                }
            )
        for array in header["constants"]:
            robot = parts[1]
            model_source = scope(robots, robot)
            match = re.search(
                r"pub const arm_joints\s*:[^=]+?=\s*\.\{([^}]+)\}", model_source, re.S
            )
            actual = re.findall(r"\.(\w+)", match[1]) if match else []
            expected = [model_name(value.split("::")[-1]) for value in array["values"]]
            checks.require(
                actual == expected,
                f"Arm joint ordering changed: {header['source']}:{array['name']}",
            )
            arrays.append(
                {
                    "source": header["source"],
                    "upstream": array["name"],
                    "zig": f"robots.{robot}.arm_joints",
                    "values": actual,
                }
            )
        for item in header["functions"]:
            mapping = {
                "crc16_core": ("src/crc.zig", "crc16"),
                "crc32_core": ("src/crc.zig", "fromWords"),
                "shutdown": ("src/robots.zig", "shutdown"),
            }
            checks.require(
                item["name"] in mapping,
                f"Unmapped wrapper function {header['source']}:{item['name']}",
            )
            if item["name"] in mapping:
                file, name = mapping[item["name"]]
                target = expect_function(file, name)
                rows.append(
                    {
                        "source": header["source"],
                        "upstream": item["signature"],
                        "targets": [target],
                    }
                )
        if parts[0] != "robots":
            continue
        direction = "publisher" if parts[-1].endswith("_pub.h") else "subscription"
        for cls in header["classes"]:
            robot = parts[1]
            target = f"robots.{robot}.{direction}.{cls['name']}"
            model_scope = zig_scope(robots, [robot, direction])
            alias = re.search(
                rf"pub const {re.escape(cls['name'])}\s*=\s*([^;]+);", model_scope
            )
            checks.require(alias is not None, f"Missing robot topic wrapper {target}")
            for member in cls["public_members"]:
                member_targets = []
                note = "Typed Zig convenience wrapper; explicit ownership replaces shared_ptr"
                if re.match(rf"(?:explicit\s+)?{re.escape(cls['name'])}\s*\(", member):
                    member_targets = [target + ".init", target + ".initTopic"]
                    topic = re.search(r'"(rt/[^"]+)"', member)
                    if topic:
                        checks.require(
                            alias is not None and topic[0] in alias[1],
                            f"Default topic differs: {target}",
                        )
                    elif direction == "publisher":
                        member_targets = [
                            target + ".init",
                            target + ".initDefault",
                            target + ".resize",
                        ]
                elif "check_mode_machine(" in member:
                    member_targets = [
                        expect_function("src/robots.zig", "checkModeMachine")
                    ]
                    note = "Explicit command and state pointers replace implicit singleton lookup"
                elif re.search(r"\bweight\s*\(", member):
                    name = (
                        "setArmWeight"
                        if re.search(r"weight\s*\(float", member)
                        else "armWeight"
                    )
                    checks.require(
                        re.search(rf"pub fn {name}\b", scope(robots, robot))
                        is not None,
                        f"Missing {robot}.{name}",
                    )
                    member_targets = [f"robots.{robot}.{name}"]
                elif "JOINTS" in member:
                    member_targets = [f"robots.{robot}.arm_joints"]
                elif "joystick" in member:
                    member_targets = [
                        "robots.PreparedPublisher.joystick"
                        if direction == "publisher"
                        else "robots.JoystickMonitor.joystick"
                    ]
                    checks.require(
                        "joystick:" in robots,
                        f"Missing joystick state storage for {target}",
                    )
                elif "update()" in member:
                    member_targets = [expect_function("src/robots.zig", "update")]
                    note = "JoystickMonitor.update accepts the received state packet and explicit monotonic time"
                elif "isJoystickTimeout(" in member:
                    member_targets = [
                        expect_function("src/robots.zig", "isJoystickTimeout")
                    ]
                else:
                    named = next(
                        (
                            name
                            for name in ("gaitType", "position", "velocity")
                            if name + "(" in member
                        ),
                        None,
                    )
                    if named:
                        member_targets = [expect_function("src/robots.zig", named)]
                checks.require(
                    bool(member_targets),
                    f"Unmapped robot convenience member: {header['source']}:{cls['name']}:{member}",
                )
                rows.append(
                    {
                        "source": header["source"],
                        "class": cls["name"],
                        "upstream": member,
                        "targets": member_targets,
                        "adaptation": note,
                    }
                )
    # Message enum constants and client enum values have independent source checks.
    point_source = (cpp_root / "include/unitree/idl/ros2/PointField_.hpp").read_text(
        encoding="utf-8"
    )
    point_expected = {
        name.lower(): int(value)
        for name, value in re.findall(r"const uint8_t (\w+)_ = (\d+);", point_source)
    }
    point_actual = enum_values(checks.read("src/messages.zig"), "PointFieldType")
    checks.require(point_actual == point_expected, "DDS PointField enum values changed")
    enum_rows.append(
        {
            "source": "include/unitree/idl/ros2/PointField_.hpp",
            "upstream": "PointField_Constants",
            "zig": "messages.PointFieldType",
            "values": point_actual,
        }
    )
    mode_source = (
        cpp_root / "include/unitree/robot/g1/loco/g1_loco_api.hpp"
    ).read_text(encoding="utf-8")
    mode_match = re.search(r"enum class InternalFsmMode\s*\{([^}]+)\}", mode_source)
    mode_expected = {
        name.strip().lower(): index
        for index, name in enumerate(mode_match[1].split(","))
    }
    mode_actual = enum_values(checks.read("src/clients.zig"), "InternalFsmMode")
    checks.require(mode_actual == mode_expected, "InternalFsmMode values changed")
    enum_rows.append(
        {
            "source": "include/unitree/robot/g1/loco/g1_loco_api.hpp",
            "upstream": "InternalFsmMode",
            "zig": "clients.InternalFsmMode",
            "values": mode_actual,
        }
    )
    # SDK action maps and supplemental preset maps have separate protocol IDs.
    for robot in ("g1", "h2"):
        header = (
            cpp_root
            / f"include/unitree/robot/{robot}/arm/{robot}_arm_action_client.hpp"
        )
        source = header.read_text(encoding="utf-8")
        match = re.search(r"action_map\s*=\s*\{(.*?)\};", source, re.S)
        expected = {
            name: int(value)
            for name, value in re.findall(r'\{\s*"([^"]+)"\s*,\s*(\d+)\s*\}', match[1])
        }
        action_scope = zig_scope(constants, [robot, "arm"])
        match = re.search(
            r"pub const actions\s*=\s*\[_\]struct\s*\{[^{}]+\}\s*\{(.*?)\};",
            action_scope,
            re.S,
        )
        actual = {
            name: int(value)
            for name, value in re.findall(
                r'\.name\s*=\s*"([^"]+)"\s*,\s*\.id\s*=\s*(\d+)',
                match[1] if match else "",
            )
        }
        checks.require(actual == expected, f"C++ {robot} action map differs")
        actions.append(
            {"origin": "C++", "zig": f"constants.{robot}.arm.actions", "values": actual}
        )
    expected = clients_generator.protocol_metadata()["g1_preset_actions"]
    match = re.search(
        r"pub const preset_actions\s*=\s*\[_\]struct\s*\{[^{}]+\}\s*\{(.*?)\};",
        zig_scope(constants, ["g1", "arm"]),
        re.S,
    )
    actual = {
        name: int(value)
        for name, value in re.findall(
            r'\.name\s*=\s*"([^"]+)"\s*,\s*\.id\s*=\s*(\d+)', match[1] if match else ""
        )
    }
    checks.require(
        actual == expected, "G1 preset action map differs from its reference"
    )
    actions.append(
        {
            "origin": "protocol_extension",
            "zig": "constants.g1.arm.preset_actions",
            "values": actual,
        }
    )
    # These helpers are free functions duplicated for G1/H2 upstream.
    terminations = []
    term_map = {
        "bad_orientation": "badOrientation",
        "joint_vel_out_of_limit": "jointVelocityOutOfLimit",
        "ang_vel_out_of_limit": "angularVelocityOutOfLimit",
        "motor_winding_overheat": "motorWindingOverheat",
        "motor_casing_overheat": "motorCasingOverheat",
        "low_battery": "lowBattery",
        "lost_connection": "lostConnection",
    }
    for robot in ("g1", "h2"):
        source_path = f"include/unitree/robot/{robot}/common/terminations.hpp"
        source = (cpp_root / source_path).read_text(encoding="utf-8")
        for name in re.findall(r"\bbool\s+(\w+)\s*\(", clean(source)):
            checks.require(
                name in term_map, f"Unknown termination helper: {robot}/{name}"
            )
            if name in term_map:
                target = expect_function("src/termination.zig", term_map[name])
                terminations.append(
                    {"source": source_path, "upstream": name, "zig": target}
                )
    common_rows = []
    scheduling = checks.read("src/scheduling.zig")
    real_time = function(scheduling, "RealtimePublisher", zig=True)
    cached = function(scheduling, "CachedSubscriber", zig=True)
    state_cache_factory = function(scheduling, "StateCache", zig=True)
    checks.require(
        "returnSnapshotCache(T,DdsStorage(T));" in compact(state_cache_factory),
        "StateCache must specialize SnapshotCache with owned DDS storage",
    )
    state_cache = function(scheduling, "SnapshotCache", zig=True)
    for header in upstream["dds_wrappers"]:
        if not header["source"].startswith("common/"):
            continue
        for cls in header["classes"]:
            for member in cls["public_members"]:
                target = None
                note = "Zig ownership and explicit Io replace C++ shared ownership and implicit threads"
                if cls["name"] == "PublisherBase":
                    target = "channel.Publisher.init"
                    checks.implementation("src/channel.zig", "init", zig=True)
                elif cls["name"] == "RealTimePublisher":
                    name = next(
                        (
                            a
                            for a in (
                                "stop",
                                "trylock",
                                "unlockAndPublish",
                                "lock",
                                "unlock",
                            )
                            if re.search(rf"\b{a}\(", member)
                        ),
                        None,
                    )
                    if name:
                        actual_name = "tryLock" if name == "trylock" else name
                        function(real_time, actual_name, zig=True)
                        target = "scheduling.RealtimePublisher." + actual_name
                    elif "msg_" in member:
                        checks.require(
                            "message:" in real_time,
                            "RealtimePublisher lacks shared message storage",
                        )
                        target = "scheduling.RealtimePublisher.message"
                    elif "RealTimePublisher(" in member:
                        target = "scheduling.RealtimePublisher." + (
                            "deinit" if "~" in member else "init/start"
                        )
                elif cls["name"] == "SubscriptionBase":
                    mappings = {
                        "set_timeout_ms": "setTimeoutMs",
                        "isTimeout": "isTimeout",
                        "wait_for_connection": "waitForConnection",
                    }
                    name = next((a for a in mappings if a + "(" in member), None)
                    if name:
                        function(cached, mappings[name], zig=True)
                        target = "scheduling.CachedSubscriber." + mappings[name]
                    elif "SubscriptionBase(" in member:
                        target = "scheduling.CachedSubscriber.init/start"
                    elif "msg_" in member:
                        function(state_cache, "withLatest", zig=True)
                        function(state_cache, "snapshot", zig=True)
                        target = "scheduling.CachedSubscriber.cache.withLatest/snapshot"
                        note = "Locked borrowed access or an owned deep snapshot replaces unsynchronized public message reads"
                    elif "mutex_" in member:
                        checks.require(
                            "mutex:" in state_cache, "StateCache mutex missing"
                        )
                        target = "scheduling.CachedSubscriber.cache.mutex"
                elif cls["name"] == "KeyBase":
                    target = "remote_control.KeyState"
                    field = re.search(r"(?:bool|int|float)\s+(\w+)", member)
                    if field:
                        field_name = (
                            "click_count" if field[1] == "click_cnt" else field[1]
                        )
                        checks.require(
                            field_name + ":" in scope(remote, "KeyState"),
                            f"Missing key state field {field_name}",
                        )
                        target += "." + field_name
                elif cls["name"] == "Button":
                    target = "remote_control.KeyState.update/pressed"
                    function(scope(remote, "KeyState"), "update", zig=True)
                    note = "Robot buttons use boolean state; arbitrary host-side C++ Button<T> templates are not exported"
                elif cls["name"] == "Axis":
                    target = "remote_control.JoystickAxis"
                    function(scope(remote, "JoystickAxis"), "update", zig=True)
                    field = re.search(r"float\s+(\w+)", member)
                    if field:
                        checks.require(
                            field[1] + ":" in scope(remote, "JoystickAxis"),
                            f"Missing joystick axis field {field[1]}",
                        )
                        target += "." + field[1]
                elif cls["name"] == "UnitreeJoystick":
                    target = "remote_control.Joystick"
                    name = next(
                        (a for a in ("extract", "combine") if a + "(" in member), None
                    )
                    if name:
                        function(scope(remote, "Joystick"), name, zig=True)
                        target += "." + name
                    elif "update()" in member:
                        note = "The empty virtual host-device polling hook is application-owned; received packets enter through extract"
                    elif "Button<" in member:
                        target += ".button/keys/ls/rs"
                    elif "Axis " in member:
                        field_name = member.split()[-1].lower()
                        checks.require(
                            field_name + ":" in scope(remote, "Joystick"),
                            f"Missing joystick field {field_name}",
                        )
                        target += "." + field_name
                checks.require(
                    target is not None,
                    f"Unmapped common wrapper member: {header['source']}:{cls['name']}:{member}",
                )
                common_rows.append(
                    {
                        "source": header["source"],
                        "class": cls["name"],
                        "upstream": member,
                        "target": target,
                        "adaptation": note,
                    }
                )
        for type_name in header["types"]:
            checks.require(
                type_name in {"BtnUnion", "BtnDataStruct", "REMOTE_DATA_RX"},
                f"Unknown joystick wire type {type_name}",
            )
            common_rows.append(
                {
                    "source": header["source"],
                    "upstream": type_name,
                    "target": "remote_control.Remote/Buttons",
                    "adaptation": "Explicit 40-byte little-endian encode/decode replaces C++ union reinterpretation",
                }
            )
    return {
        "model_members": rows,
        "common_members": common_rows,
        "enums": enum_rows,
        "arm_joint_arrays": arrays,
        "action_maps": actions,
        "termination_helpers": terminations,
        "common_headers": [
            {
                "source": h["source"],
                "sha256": h["sha256"],
                "classes": h["classes"],
                "types": h["types"],
            }
            for h in upstream["dds_wrappers"]
            if h["source"].startswith("common/")
        ],
    }


def check_zig_utilities(checks: Checks) -> list[dict]:
    # These are the library's own public utilities, not external language APIs.
    specifications = [
        (
            "sync",
            "BoundedQueue",
            "init put get size interrupt close clear deinit",
            "Accepted items transfer ownership; replacement returns the displaced item. Clear requires a disposal callback.",
        ),
        (
            "sync",
            "Future",
            "init ready fail wait getResult close deinit",
            "Single completion; repeated reads share shallow values. Failure text is owned by the Future.",
        ),
        (
            "remote_control",
            "ButtonState",
            "update resetClickCount",
            "Explicit monotonic timestamp, 300 ms click window, first click count zero.",
        ),
        (
            "remote_control",
            "AxisState",
            "update",
            "Absolute-value threshold and strict previous-sample edge comparisons.",
        ),
        (
            "remote_control",
            "RemoteTracker",
            "init button extract extractPacket resetAllClickCounts combine",
            "Four axes and 14 active buttons; 500 ms idle click reset. F1/F2 are excluded.",
        ),
        (
            "scheduling",
            "FrequencySampler",
            "init sample take reset",
            "Atomic sample count; caller supplies timestamps and receives a rate.",
        ),
        (
            "scheduling",
            "PeriodicTask",
            "init start stop stats deinit",
            "Explicit start/stop/join and callback error statistics. Zero interval runs a cooperative continuous loop.",
        ),
        (
            "crc",
            None,
            "crc16 fromWords fromBytes encodedSize encode compute update verify",
            "Stateless field-wise checksums for four low-level message layouts, plus CRC16.",
        ),
    ]
    records = []
    for module, container, names, behavior in specifications:
        source = checks.read(f"src/{module}.zig")
        if container is None:
            body = source
        elif module == "sync":
            body = function(source, container, zig=True)
        else:
            body = scope(source, container)
        expected = set(names.split())
        actual = set(re.findall(r"\bpub\s+fn\s+(\w+)\s*\(", clean(body)))
        if module == "sync":
            actual.discard(container)  # The generic factory encloses its methods.
        checks.require(
            actual == expected,
            f"Zig utility method inventory changed: {module}.{container}",
        )
        methods = []
        for name in names.split():
            implementation = function(body, name, zig=True)
            methods.append({"name": name, "sha256": digest(compact(implementation))})
        records.append(
            {
                "zig": module + ("." + container if container else ""),
                "source": f"src/{module}.zig",
                "methods": methods,
                "behavior": behavior,
            }
        )
    remote = checks.read("src/remote_control.zig")
    button = compact(scope(remote, "ButtonState"))
    tracker = compact(scope(remote, "RemoteTracker"))
    checks.require(
        "click_interval_ns:i64=300_000_000" in button,
        "ButtonState click window changed",
    )
    checks.require(
        "inactive_timeout_ns:i64=500_000_000" in tracker
        and "self.resetAllClickCounts();" in tracker,
        "RemoteTracker idle click reset is missing",
    )
    return records


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--sdk", type=Path, required=True, help="SDK directory resolved by Zig"
    )
    parser.add_argument(
        "--report", type=Path, default=ROOT / "tests/reference/coverage.json"
    )
    parser.add_argument("--write", action="store_true")
    parser.add_argument(
        "--check", action="store_true", help="Explicit alias for the default check mode"
    )
    args = parser.parse_args()
    checks = Checks(ROOT)
    upstream = audit.inventory(args.sdk)
    cpp_methods, extensions, aliases = check_clients(checks, upstream, args.sdk)
    message_records = check_messages(checks, upstream, args.sdk)
    constant_records = check_constants(checks, upstream)
    helper_records = check_helpers(checks, upstream, args.sdk)
    utility_records = check_zig_utilities(checks)
    report = {
        "schema_version": 3,
        "scope": "C++ SDK bindings, DDS messages, supplemental protocol extensions, convenience aliases, and Zig utilities",
        "verification_boundary": "Static source/schema/routing verification plus independent upstream inventory; not physical robot or firmware execution",
        "sdk": upstream["sdk"],
        "counts": {
            "cpp_clients": len(upstream["cpp_clients"]),
            "cpp_methods_excluding_init": len(cpp_methods)
            - len(upstream["cpp_clients"]),
            "cpp_methods_with_init_and_overloads": len(cpp_methods),
            "protocol_extension_methods": len(extensions),
            "convenience_aliases": len(aliases),
            "dds_messages": len(message_records),
            "cpp_constants": len(constant_records["cpp"]),
            "protocol_variant_constants": len(constant_records["protocol_variants"]),
            "zig_utility_groups": len(utility_records),
        },
        "cpp_methods": cpp_methods,
        "protocol_extensions": extensions,
        "convenience_aliases": aliases,
        "messages": message_records,
        "constants": constant_records,
        "helpers": helper_records,
        "zig_utilities": utility_records,
    }
    if checks.errors:
        print(
            json.dumps(
                {"coverage_errors": checks.errors}, ensure_ascii=False, indent=2
            ),
            file=sys.stderr,
        )
        return 1
    encoded = json.dumps(report, ensure_ascii=False, indent=2) + "\n"
    if not check_or_write(args.report, encoded, check=not args.write, kind="json"):
        print(
            "Coverage evidence is stale; review changes and run zig build regenerate -Dsdk-tools",
            file=sys.stderr,
        )
        return 1
    report_path = args.report.resolve()
    display_path = (
        report_path.relative_to(ROOT)
        if report_path.is_relative_to(ROOT)
        else report_path
    )
    print(
        json.dumps(
            {"verified": report["counts"], "report": display_path.as_posix()},
            ensure_ascii=False,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

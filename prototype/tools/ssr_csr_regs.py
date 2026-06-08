#!/usr/bin/env python3
"""
SSR CSR Tool

Project-level bring-up/debug/configuration tool for the SSR FPGA application.

This tool manages the sysfs interface exposed by mqnic_app_ssr:

    /sys/bus/auxiliary/devices/mqnic.app_xxxxxxxx.0/

It supports:

    smoke   Run CSR smoke test
    dump    Dump current CSR state
    config  Write replica configuration
    mac     Write MAC table entry or JSON MAC table
    control Write raw control register
    enable  Set CONTROL.enable
    disable Clear CONTROL.enable

This tool is not part of the performance-critical SSR runtime.
The production host-side runtime is expected to be implemented in C/C++.
"""

from __future__ import annotations

import argparse
import json
import os
import random
import re
import sys
from pathlib import Path
from typing import Any


AUX_BUS_PATH = Path("/sys/bus/auxiliary/devices")

DEFAULT_AUX_NAME_FALLBACK = "mqnic.app_53535201.0"
DEFAULT_MAX_REPLICAS_FALLBACK = 7


class Style:
    RESET = "\033[0m"
    BOLD = "\033[1m"
    DIM = "\033[2m"

    RED = "\033[31m"
    GREEN = "\033[32m"
    YELLOW = "\033[33m"
    BLUE = "\033[34m"
    CYAN = "\033[36m"


USE_COLOR = sys.stdout.isatty() and os.environ.get("NO_COLOR") is None


def color(text: str, *styles: str) -> str:
    if not USE_COLOR:
        return text
    return "".join(styles) + text + Style.RESET


def section(text: str) -> None:
    print()
    print(color(text, Style.BOLD, Style.CYAN))


def label(name: str, value: str) -> None:
    print(f"  {color(name + ':', Style.BOLD)} {value}")


def info(text: str) -> None:
    print(color(text, Style.BLUE))


def ok(text: str) -> None:
    print(color(text, Style.GREEN))


def warn(text: str) -> None:
    print(color(text, Style.YELLOW))


def fail(text: str) -> None:
    print(color(text, Style.RED, Style.BOLD), file=sys.stderr)


class CSRError(RuntimeError):
    pass


# ---------------------------------------------------------------------------
# Header parsing
# ---------------------------------------------------------------------------

def find_project_root(start: Path | None = None) -> Path | None:
    cur = (start or Path(__file__)).resolve()
    if cur.is_file():
        cur = cur.parent

    for p in [cur, *cur.parents]:
        if (p / "host" / "include" / "ssr_regs.h").exists():
            return p

    return None


def parse_simple_c_macros(header_path: Path) -> dict[str, Any]:
    macros: dict[str, Any] = {}

    if not header_path.exists():
        return macros

    define_re = re.compile(
        r"^\s*#define\s+([A-Za-z_][A-Za-z0-9_]*)\s+(.+?)\s*(?://.*|/\*.*\*/)?\s*$"
    )

    for line in header_path.read_text().splitlines():
        m = define_re.match(line)
        if not m:
            continue

        name, value = m.group(1), m.group(2).strip()

        if "/*" in value:
            value = value.split("/*", 1)[0].strip()
        if "//" in value:
            value = value.split("//", 1)[0].strip()

        if value.startswith('"') and value.endswith('"'):
            macros[name] = value[1:-1]
            continue

        value_no_suffix = re.sub(r"([0-9a-fA-FxX]+)[uUlL]+$", r"\1", value)

        try:
            macros[name] = int(value_no_suffix, 0)
        except ValueError:
            macros[name] = value

    return macros


def load_defaults_from_header() -> tuple[str, int]:
    root = find_project_root()
    if root is None:
        return DEFAULT_AUX_NAME_FALLBACK, DEFAULT_MAX_REPLICAS_FALLBACK

    regs = parse_simple_c_macros(root / "host" / "include" / "ssr_regs.h")

    if "SSR_AUXILIARY_NAME" in regs:
        aux_name = f"{regs['SSR_AUXILIARY_NAME']}.0"
    elif "SSR_APP_ID" in regs and isinstance(regs["SSR_APP_ID"], int):
        aux_name = f"mqnic.app_{regs['SSR_APP_ID']:08x}.0"
    else:
        aux_name = DEFAULT_AUX_NAME_FALLBACK

    max_replicas = regs.get("SSR_MAX_REPLICAS", DEFAULT_MAX_REPLICAS_FALLBACK)
    if not isinstance(max_replicas, int):
        max_replicas = DEFAULT_MAX_REPLICAS_FALLBACK

    return aux_name, max_replicas


DEFAULT_AUX_NAME, DEFAULT_MAX_REPLICAS = load_defaults_from_header()


# ---------------------------------------------------------------------------
# sysfs helpers
# ---------------------------------------------------------------------------

def read_text(path: Path) -> str:
    try:
        return path.read_text().strip()
    except OSError as e:
        raise CSRError(f"failed to read {path}: {e}") from e


def write_text(path: Path, value: str) -> None:
    try:
        path.write_text(value)
    except PermissionError as e:
        raise CSRError(f"permission denied writing {path}; try running with sudo") from e
    except OSError as e:
        raise CSRError(f"failed to write {path}: {e}") from e


def parse_u32(text: str) -> int:
    try:
        return int(text.strip(), 0)
    except ValueError as e:
        raise CSRError(f"failed to parse {text!r} as integer") from e


def require_file(dev_path: Path, name: str) -> Path:
    path = dev_path / name
    if not path.is_file():
        raise CSRError(f"required sysfs file not found: {path}")
    return path


def find_device(aux_name: str | None) -> Path:
    if aux_name:
        dev_path = AUX_BUS_PATH / aux_name
        if not dev_path.exists():
            raise CSRError(f"auxiliary device not found: {dev_path}")
        return dev_path

    candidates = sorted(AUX_BUS_PATH.glob("mqnic.app_*"))
    if not candidates:
        raise CSRError(f"no mqnic application auxiliary devices found in {AUX_BUS_PATH}")

    if len(candidates) > 1:
        names = ", ".join(p.name for p in candidates)
        raise CSRError(f"multiple mqnic app devices found: {names}; use --aux-name")

    return candidates[0]


# ---------------------------------------------------------------------------
# decode / parse helpers
# ---------------------------------------------------------------------------

def decode_features(value: int) -> list[str]:
    flags: list[str] = []

    if value & 0x1:
        flags.append("config")
    if value & 0x2:
        flags.append("mac_table")
    if value & 0x4:
        flags.append("scratch")
    if value & 0x8:
        flags.append("status")

    unknown = value & ~0xf
    if unknown:
        flags.append(f"unknown=0x{unknown:08x}")

    return flags


def decode_status(value: int) -> list[str]:
    flags: list[str] = []

    if value & 0x1:
        flags.append("config_valid")
    if value & 0x2:
        flags.append("enabled")
    if value & 0x4:
        flags.append("soft_reset")

    unknown = value & ~0x7
    if unknown:
        flags.append(f"unknown=0x{unknown:08x}")

    return flags


def decode_control(value: int) -> list[str]:
    flags: list[str] = []

    if value & 0x1:
        flags.append("enable")
    if value & 0x2:
        flags.append("soft_reset")

    unknown = value & ~0x3
    if unknown:
        flags.append(f"unknown=0x{unknown:08x}")

    return flags


def format_flags(flags: list[str]) -> str:
    if not flags:
        return color("(none)", Style.DIM)
    return ", ".join(flags)


def parse_config(text: str) -> tuple[int, int, int, int]:
    parts = text.split()
    if len(parts) != 4:
        raise CSRError(f"config has unexpected format: {text!r}")

    try:
        return tuple(int(x, 0) for x in parts)  # type: ignore[return-value]
    except ValueError as e:
        raise CSRError(f"config contains non-integer value: {text!r}") from e


def normalize_mac(mac: str) -> str:
    mac = mac.strip().lower()

    if re.fullmatch(r"[0-9a-f]{2}(:[0-9a-f]{2}){5}", mac):
        return mac

    raise CSRError(f"invalid MAC address format: {mac!r}; expected aa:bb:cc:dd:ee:ff")


def parse_mac_table(text: str) -> dict[int, str]:
    table: dict[int, str] = {}

    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue

        parts = line.split()
        if len(parts) != 2:
            raise CSRError(f"MAC table line has unexpected format: {line!r}")

        try:
            index = int(parts[0], 0)
        except ValueError as e:
            raise CSRError(f"invalid MAC table index in line: {line!r}") from e

        table[index] = parts[1].lower()

    return table


# ---------------------------------------------------------------------------
# read / write operations
# ---------------------------------------------------------------------------

def read_basic(dev_path: Path) -> dict[str, str]:
    return {
        "features": read_text(require_file(dev_path, "features")),
        "status": read_text(require_file(dev_path, "status")),
        "control": read_text(require_file(dev_path, "control")),
        "scratch": read_text(require_file(dev_path, "scratch")),
        "config": read_text(require_file(dev_path, "config")),
        "mac_table": read_text(require_file(dev_path, "mac_table")),
    }


def write_config(
    dev_path: Path,
    replica_id: int,
    replica_count: int,
    round_length_ns: int,
    ethernet_type: int,
    verify: bool = True,
) -> None:
    config_path = require_file(dev_path, "config")

    line = f"{replica_id} {replica_count} {round_length_ns} {ethernet_type}\n"
    info(f"  config <- {line.strip()}")
    write_text(config_path, line)

    if verify:
        actual = parse_config(read_text(config_path))
        expected = (replica_id, replica_count, round_length_ns, ethernet_type)

        info(f"  config -> {actual}")

        if actual != expected:
            raise CSRError(f"config verify failed: expected {expected}, got {actual}")

        ok("  PASS: config verified")


def write_mac_entry(
    dev_path: Path,
    index: int,
    mac: str,
    max_replicas: int,
    verify: bool = True,
) -> None:
    if index < 0 or index >= max_replicas:
        raise CSRError(f"MAC table index {index} out of range [0, {max_replicas - 1}]")

    mac = normalize_mac(mac)
    mac_table_path = require_file(dev_path, "mac_table")

    line = f"{index} {mac}\n"
    info(f"  mac_table <- {line.strip()}")
    write_text(mac_table_path, line)

    if verify:
        table = parse_mac_table(read_text(mac_table_path))
        actual = table.get(index)

        info(f"  mac_table[{index}] -> {actual}")

        if actual != mac:
            raise CSRError(f"MAC verify failed at index {index}: expected {mac}, got {actual}")

        ok(f"  PASS: MAC table entry {index} verified")


def load_mac_json(path: Path) -> list[tuple[int, str]]:
    try:
        data = json.loads(path.read_text())
    except OSError as e:
        raise CSRError(f"failed to read MAC JSON file {path}: {e}") from e
    except json.JSONDecodeError as e:
        raise CSRError(f"failed to parse MAC JSON file {path}: {e}") from e

    entries: list[tuple[int, str]] = []

    if isinstance(data, dict):
        for key, value in data.items():
            try:
                index = int(key, 0)
            except ValueError as e:
                raise CSRError(f"invalid MAC table index in JSON: {key!r}") from e

            if not isinstance(value, str):
                raise CSRError(f"MAC value for index {index} must be a string")

            entries.append((index, normalize_mac(value)))

    elif isinstance(data, list):
        for item in data:
            if not isinstance(item, dict):
                raise CSRError("MAC JSON list entries must be objects")

            if "index" not in item or "mac" not in item:
                raise CSRError("MAC JSON list entries must contain 'index' and 'mac'")

            index = int(item["index"])
            mac = normalize_mac(str(item["mac"]))
            entries.append((index, mac))

    else:
        raise CSRError("MAC JSON must be either an object or a list")

    return sorted(entries)


def write_mac_json(
    dev_path: Path,
    path: Path,
    max_replicas: int,
    verify: bool = True,
) -> None:
    entries = load_mac_json(path)

    for index, mac in entries:
        write_mac_entry(dev_path, index, mac, max_replicas, verify=False)

    if verify:
        table = parse_mac_table(read_text(require_file(dev_path, "mac_table")))

        for index, mac in entries:
            actual = table.get(index)
            if actual != mac:
                raise CSRError(f"MAC verify failed at index {index}: expected {mac}, got {actual}")

        ok("  PASS: MAC JSON entries verified")


def write_control(dev_path: Path, value: int, verify: bool = True) -> None:
    control_path = require_file(dev_path, "control")

    info(f"  control <- 0x{value:08x}")
    write_text(control_path, f"0x{value:08x}\n")

    if verify:
        actual = parse_u32(read_text(control_path))
        info(f"  control -> 0x{actual:08x}")

        if actual != value:
            raise CSRError(f"control verify failed: expected 0x{value:08x}, got 0x{actual:08x}")

        ok("  PASS: control verified")


def write_scratch(dev_path: Path, value: int, verify: bool = True) -> None:
    scratch_path = require_file(dev_path, "scratch")

    info(f"  scratch <- 0x{value:08x}")
    write_text(scratch_path, f"0x{value:08x}\n")

    if verify:
        actual = parse_u32(read_text(scratch_path))
        info(f"  scratch -> 0x{actual:08x}")

        if actual != value:
            raise CSRError(f"scratch verify failed: expected 0x{value:08x}, got 0x{actual:08x}")

        ok("  PASS: scratch verified")


# ---------------------------------------------------------------------------
# subcommands
# ---------------------------------------------------------------------------

def cmd_dump(args: argparse.Namespace) -> int:
    dev_path = find_device(args.aux_name)

    section("Device")
    label("auxiliary device", str(dev_path))
    label("device name", dev_path.name)

    values = read_basic(dev_path)

    features = parse_u32(values["features"])
    status = parse_u32(values["status"])
    control = parse_u32(values["control"])
    scratch = parse_u32(values["scratch"])

    section("Basic CSR")
    label("features", f"0x{features:08x} ({format_flags(decode_features(features))})")
    label("status", f"0x{status:08x} ({format_flags(decode_status(status))})")
    label("control", f"0x{control:08x} ({format_flags(decode_control(control))})")
    label("scratch", f"0x{scratch:08x}")

    section("Configuration")
    replica_id, replica_count, round_length_ns, ethernet_type = parse_config(values["config"])
    label("replica_id", str(replica_id))
    label("replica_count", str(replica_count))
    label("round_length_ns", str(round_length_ns))
    label("ethernet_type", f"0x{ethernet_type:04x} ({ethernet_type})")

    if status & 0x1:
        label("config_valid", color("yes", Style.GREEN))
    else:
        label("config_valid", color("no", Style.YELLOW))

    section("MAC Table")
    table = parse_mac_table(values["mac_table"])
    if not table:
        warn("  MAC table is empty")
    else:
        for index in sorted(table):
            print(f"  {color(str(index).rjust(2), Style.BOLD)}  {table[index]}")

    return 0


def cmd_smoke(args: argparse.Namespace) -> int:
    dev_path = find_device(args.aux_name)

    section(f"Testing auxiliary device at {dev_path}")

    section("[1/5] Reading basic CSR files")
    values = read_basic(dev_path)
    info(f"  features : {values['features']}")
    info(f"  status   : {values['status']}")
    info(f"  control  : {values['control']}")
    info(f"  scratch  : {values['scratch']}")
    info(f"  config   : {values['config']}")
    info(f"  mac_table: {len(values['mac_table'].splitlines())} entries")
    ok("  PASS: Basic CSR files are readable")

    section("[2/5] Testing scratch register R/W")
    write_scratch(dev_path, args.scratch_value, verify=True)

    section("[3/5] Testing config register R/W")
    write_config(
        dev_path,
        args.replica_id,
        args.replica_count,
        args.round_length_ns,
        args.ethernet_type,
        verify=True,
    )

    section("[4/5] Testing MAC table R/W")
    entries: list[str] = []
    for _ in range(args.mac_table_size):
        suffix = random.randint(0, 255)
        entries.append(f"de:ad:be:ef:00:{suffix:02x}")

    for index, mac in enumerate(entries):
        write_mac_entry(dev_path, index, mac, args.max_replicas, verify=False)

    table = parse_mac_table(read_text(require_file(dev_path, "mac_table")))

    info("  Read back MAC table entries:")
    for index in sorted(table):
        print(f"    {index} {table[index]}")

    for index, expected_mac in enumerate(entries):
        actual_mac = table.get(index)
        if actual_mac != expected_mac:
            raise CSRError(
                f"MAC table mismatch at index {index}: wrote {expected_mac}, read back {actual_mac}"
            )

    ok("  PASS: MAC table R/W test passed")

    section("[5/5] Testing status flags")
    status = parse_u32(read_text(require_file(dev_path, "status")))
    control = parse_u32(read_text(require_file(dev_path, "control")))
    info(f"  status : 0x{status:08x}")
    info(f"  control: 0x{control:08x}")

    if status & 0x1:
        ok("  PASS: status.config_valid appears to be set")
    else:
        warn("  WARN: status.config_valid is not set")

    ok("SSR smoke test passed successfully")
    return 0


def cmd_config(args: argparse.Namespace) -> int:
    dev_path = find_device(args.aux_name)

    section(f"Using auxiliary device {dev_path}")

    write_config(
        dev_path,
        args.replica_id,
        args.replica_count,
        args.round_length_ns,
        args.ethernet_type,
        verify=not args.no_verify,
    )

    if args.dump:
        cmd_dump(args)

    ok("SSR configuration completed successfully")
    return 0


def cmd_mac(args: argparse.Namespace) -> int:
    dev_path = find_device(args.aux_name)

    section(f"Using auxiliary device {dev_path}")

    if args.index is not None or args.mac is not None:
        if args.index is None or args.mac is None:
            raise CSRError("--index and --mac must be used together")

        write_mac_entry(
            dev_path,
            args.index,
            args.mac,
            args.max_replicas,
            verify=not args.no_verify,
        )

    if args.json is not None:
        section(f"Writing MAC table from {args.json}")
        write_mac_json(
            dev_path,
            args.json,
            args.max_replicas,
            verify=not args.no_verify,
        )

    if args.index is None and args.mac is None and args.json is None:
        raise CSRError("nothing to do; use --index/--mac or --json")

    if args.dump:
        cmd_dump(args)

    ok("SSR MAC table configuration completed successfully")
    return 0


def cmd_control(args: argparse.Namespace) -> int:
    dev_path = find_device(args.aux_name)

    section(f"Using auxiliary device {dev_path}")
    write_control(dev_path, args.value, verify=not args.no_verify)

    if args.dump:
        cmd_dump(args)

    ok("SSR control update completed successfully")
    return 0


def cmd_enable(args: argparse.Namespace) -> int:
    dev_path = find_device(args.aux_name)

    section(f"Using auxiliary device {dev_path}")
    write_control(dev_path, 0x1, verify=not args.no_verify)

    if args.dump:
        cmd_dump(args)

    ok("SSR enabled")
    return 0


def cmd_disable(args: argparse.Namespace) -> int:
    dev_path = find_device(args.aux_name)

    section(f"Using auxiliary device {dev_path}")
    write_control(dev_path, 0x0, verify=not args.no_verify)

    if args.dump:
        cmd_dump(args)

    ok("SSR disabled")
    return 0


def cmd_scratch(args: argparse.Namespace) -> int:
    dev_path = find_device(args.aux_name)

    section(f"Using auxiliary device {dev_path}")
    write_scratch(dev_path, args.value, verify=not args.no_verify)

    if args.dump:
        cmd_dump(args)

    ok("SSR scratch update completed successfully")
    return 0


# ---------------------------------------------------------------------------
# argparse
# ---------------------------------------------------------------------------

def add_common_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument(
        "--aux-name",
        default=DEFAULT_AUX_NAME,
        help=f"auxiliary device name, default: {DEFAULT_AUX_NAME}",
    )
    parser.add_argument(
        "--no-color",
        action="store_true",
        help="disable colored output",
    )


def add_write_common_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument(
        "--no-verify",
        action="store_true",
        help="do not read back values after writing",
    )
    parser.add_argument(
        "--dump",
        action="store_true",
        help="dump CSR state after the operation",
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="SSR CSR management, testing, and configuration tool"
    )

    subparsers = parser.add_subparsers(dest="command", required=True)

    p_dump = subparsers.add_parser("dump", help="dump current SSR CSR state")
    add_common_args(p_dump)
    p_dump.set_defaults(func=cmd_dump)

    p_smoke = subparsers.add_parser("smoke", help="run CSR smoke test")
    add_common_args(p_smoke)
    p_smoke.add_argument("--scratch-value", type=lambda x: int(x, 0), default=0x12345678)
    p_smoke.add_argument("--replica-id", type=int, default=1)
    p_smoke.add_argument("--replica-count", type=int, default=4)
    p_smoke.add_argument("--round-length-ns", type=int, default=1_000_000)
    p_smoke.add_argument("--ethernet-type", type=lambda x: int(x, 0), default=0x0800)
    p_smoke.add_argument("--mac-table-size", type=int, default=DEFAULT_MAX_REPLICAS)
    p_smoke.add_argument("--max-replicas", type=int, default=DEFAULT_MAX_REPLICAS)
    p_smoke.set_defaults(func=cmd_smoke)

    p_config = subparsers.add_parser("config", help="write SSR replica configuration")
    add_common_args(p_config)
    add_write_common_args(p_config)
    p_config.add_argument("--replica-id", type=int, required=True)
    p_config.add_argument("--replica-count", type=int, required=True)
    p_config.add_argument("--round-length-ns", type=int, required=True)
    p_config.add_argument("--ethernet-type", type=lambda x: int(x, 0), required=True)
    p_config.set_defaults(func=cmd_config)

    p_mac = subparsers.add_parser("mac", help="write SSR MAC table")
    add_common_args(p_mac)
    add_write_common_args(p_mac)
    p_mac.add_argument("--index", type=lambda x: int(x, 0), help="MAC table index")
    p_mac.add_argument("--mac", type=str, help="MAC address, e.g. de:ad:be:ef:00:01")
    p_mac.add_argument("--json", type=Path, help="JSON file containing MAC table entries")
    p_mac.add_argument("--max-replicas", type=int, default=DEFAULT_MAX_REPLICAS)
    p_mac.set_defaults(func=cmd_mac)

    p_control = subparsers.add_parser("control", help="write raw control register")
    add_common_args(p_control)
    add_write_common_args(p_control)
    p_control.add_argument("value", type=lambda x: int(x, 0), help="control value")
    p_control.set_defaults(func=cmd_control)

    p_enable = subparsers.add_parser("enable", help="set CONTROL.enable")
    add_common_args(p_enable)
    add_write_common_args(p_enable)
    p_enable.set_defaults(func=cmd_enable)

    p_disable = subparsers.add_parser("disable", help="clear CONTROL.enable")
    add_common_args(p_disable)
    add_write_common_args(p_disable)
    p_disable.set_defaults(func=cmd_disable)

    p_scratch = subparsers.add_parser("scratch", help="write scratch register")
    add_common_args(p_scratch)
    add_write_common_args(p_scratch)
    p_scratch.add_argument("value", type=lambda x: int(x, 0), help="scratch value")
    p_scratch.set_defaults(func=cmd_scratch)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()

    global USE_COLOR
    if getattr(args, "no_color", False):
        USE_COLOR = False

    try:
        return args.func(args)
    except CSRError as e:
        fail(f"ERROR: {e}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
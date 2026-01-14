#!/usr/bin/env python3
# -*- coding: utf-8 -*-
#
# SPDX-License-Identifier: ISC

from __future__ import annotations

import argparse
import bisect
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Optional


BIT_RE = re.compile(r"^(.*)\[(\d+)\]$")
RANGE_RE = re.compile(r"^(.*)\[(\d+):(\d+)\]$")


def info(enabled: bool, message: str) -> None:
    if enabled:
        sys.stderr.write(message)


def infoln(enabled: bool, message: str) -> None:
    info(enabled, message + "\n")


def binary_string_to_hex(value: Optional[str]) -> str:
    if value is None:
        return "x"
    s = str(value).strip().lower()
    if not s:
        return ""
    if len(s) == 1:
        return s
    for ch in s:
        if ch not in "01":
            return ch
    return hex(int(s, 2))[2:]


def normalize(val: Optional[str], width: int) -> Optional[str]:
    if val is None:
        return None
    try:
        width = int(width)
    except Exception:
        width = 1
    if width <= 0:
        width = 1
    if isinstance(val, str) and len(val) == 1 and width > 1 and val in "xXzZ":
        return val.lower() * width
    if isinstance(val, str):
        val = val.lower()
        if width > 1 and len(val) < width:
            val = ("0" * (width - len(val))) + val
        return val
    return str(val)


def _split_suffix(name: str) -> tuple[str, Optional[tuple[str, int, int]]]:
    if not isinstance(name, str):
        return str(name), None
    m = RANGE_RE.match(name)
    if m:
        return m.group(1), ("range", int(m.group(2)), int(m.group(3)))
    m = BIT_RE.match(name)
    if m:
        idx = int(m.group(2))
        return m.group(1), ("bit", idx, idx)
    return name, None


def _join_ref_tokens(tokens: list[str]) -> str:
    if not tokens:
        return ""
    ref = tokens[0]
    for tok in tokens[1:]:
        if tok.startswith("["):
            ref += tok
        else:
            ref += tok
    return ref


@dataclass(frozen=True)
class VCDHeader:
    signals: list[str]
    name_to_size: dict[str, int]
    name_to_code: dict[str, str]
    code_to_names: dict[str, list[str]]


def parse_vcd_header(path: Path) -> VCDHeader:
    scopes: list[str] = []
    signals: list[str] = []
    name_to_size: dict[str, int] = {}
    name_to_code: dict[str, str] = {}
    code_to_names: dict[str, list[str]] = {}

    try:
        with path.open("r", encoding="utf-8", errors="ignore") as f:
            for raw in f:
                line = raw.strip()
                if not line:
                    continue
                if line.startswith("$scope"):
                    parts = line.split()
                    if len(parts) >= 3:
                        scopes.append(parts[2])
                    continue
                if line.startswith("$upscope"):
                    if scopes:
                        scopes.pop()
                    continue
                if line.startswith("$var"):
                    parts = line.split()
                    try:
                        end_idx = parts.index("$end")
                    except ValueError:
                        end_idx = len(parts)
                    if end_idx < 5:
                        continue
                    try:
                        size = int(parts[2])
                    except ValueError:
                        continue
                    code = parts[3]
                    ref = _join_ref_tokens(parts[4:end_idx])
                    if not ref:
                        continue
                    full = ".".join(scopes + [ref]) if scopes else ref
                    signals.append(full)
                    name_to_size[full] = size
                    name_to_code[full] = code
                    code_to_names.setdefault(code, []).append(full)
                    continue
                if line.startswith("$enddefinitions"):
                    break
    except OSError as exc:
        raise RuntimeError(f"failed to read VCD header: {path}: {exc}") from exc

    return VCDHeader(
        signals=signals,
        name_to_size=name_to_size,
        name_to_code=name_to_code,
        code_to_names=code_to_names,
    )


@dataclass
class Signal:
    size: int
    tv: list[tuple[int, str]]
    endtime: int

    def __post_init__(self) -> None:
        self._times = [int(t) for t, _ in self.tv]

    def __getitem__(self, t: int) -> Optional[str]:
        if not self.tv:
            return None
        idx = bisect.bisect_right(self._times, int(t)) - 1
        if idx < 0:
            return None
        return self.tv[idx][1]


class BusSignal:
    def __init__(self, bits: dict[int, Signal], msb: int, lsb: int):
        step = -1 if msb >= lsb else 1
        self._order = list(range(msb, lsb + step, step))
        self._bits = bits
        self.size = len(self._order)
        self.endtime = max((sig.endtime for sig in bits.values()), default=0)

        merged: set[int] = set()
        for sig in bits.values():
            merged.update(int(t) for t, _ in sig.tv)
        self.tv = [(t, "") for t in sorted(merged)]

    def __getitem__(self, t: int) -> str:
        chars: list[str] = []
        for bit in self._order:
            sig = self._bits.get(bit)
            v = sig[int(t)] if sig is not None else None
            if v is None:
                chars.append("x")
                continue
            v = str(v).lower()
            if v not in ("0", "1", "x", "z"):
                v = "x"
            if v == "z":
                v = "x"
            chars.append(v)
        return "".join(chars)


@dataclass(frozen=True)
class ParsedVCD:
    signals: dict[str, Signal]
    endtime: int


def parse_vcd_values(path: Path, header: VCDHeader, needed_names: set[str]) -> ParsedVCD:
    wanted_codes: dict[str, list[str]] = {}
    for code, names in header.code_to_names.items():
        selected = [n for n in names if n in needed_names]
        if selected:
            wanted_codes[code] = selected

    tvs: dict[str, list[tuple[int, str]]] = {n: [] for n in needed_names}
    current_time = 0
    endtime = 0
    in_dumpvars = False
    in_body = False

    try:
        with path.open("r", encoding="utf-8", errors="ignore") as f:
            for raw in f:
                line = raw.strip()
                if not in_body:
                    if line.startswith("$enddefinitions"):
                        in_body = True
                    continue
                if not line:
                    continue

                if line.startswith("#"):
                    try:
                        current_time = int(line[1:].strip() or "0")
                    except ValueError:
                        current_time = 0
                    endtime = max(endtime, current_time)
                    continue

                if line.startswith("$"):
                    if line.startswith("$dumpvars"):
                        in_dumpvars = True
                        continue
                    if line.startswith("$end") and in_dumpvars:
                        in_dumpvars = False
                        continue
                    continue

                kind = line[0]
                value: str
                code: str
                if kind in ("b", "B", "r", "R"):
                    rest = line[1:].strip()
                    if not rest:
                        continue
                    parts = rest.split(None, 1)
                    if len(parts) != 2:
                        continue
                    value = parts[0].strip().lower()
                    code = parts[1].strip()
                elif kind in ("0", "1", "x", "X", "z", "Z"):
                    value = kind.lower()
                    code = line[1:].strip()
                else:
                    continue

                if not code:
                    continue
                names = wanted_codes.get(code)
                if not names:
                    continue

                for name in names:
                    tvs[name].append((current_time, value))
    except OSError as exc:
        raise RuntimeError(f"failed to read VCD values: {path}: {exc}") from exc

    signals: dict[str, Signal] = {}
    for name, tv in tvs.items():
        compressed: list[tuple[int, str]] = []
        for t, v in tv:
            if compressed and compressed[-1][0] == t:
                compressed[-1] = (t, v)
            else:
                compressed.append((t, v))
        signals[name] = Signal(
            size=header.name_to_size.get(name, 1),
            tv=compressed,
            endtime=endtime,
        )

    return ParsedVCD(signals=signals, endtime=endtime)


def filter_signals(signals: list[str], prefix: Optional[str]) -> dict[str, str]:
    if prefix is None:
        return {s: s for s in signals}
    return {s[len(prefix) :]: s for s in signals if s.startswith(prefix)}


def index_by_base(filtered: dict[str, str]) -> tuple[dict[str, tuple[int, int, str]], dict[str, dict[int, str]]]:
    ranges: dict[str, tuple[int, int, str]] = {}
    bits: dict[str, dict[int, str]] = {}
    for short, full in filtered.items():
        base, suf = _split_suffix(short)
        if suf is None:
            continue
        kind, msb, lsb = suf
        if kind == "range":
            ranges.setdefault(base, (msb, lsb, full))
        elif kind == "bit":
            bits.setdefault(base, {})[msb] = full
    return ranges, bits


def has_bits(bits: dict[int, str], msb: int, lsb: int) -> bool:
    step = -1 if msb >= lsb else 1
    for i in range(msb, lsb + step, step):
        if i not in bits:
            return False
    return True


def compare_at_times(
    key: str,
    sig_a: Any,
    width_a: int,
    sig_b: Any,
    width_b: int,
    after: Optional[int],
    before: Optional[int],
) -> Optional[tuple[int, str, str, str]]:
    endtime = max(getattr(sig_a, "endtime", 0), getattr(sig_b, "endtime", 0))
    times: set[int] = {0, int(endtime)}
    times.update(int(t) for t, _ in getattr(sig_a, "tv", []))
    times.update(int(t) for t, _ in getattr(sig_b, "tv", []))
    for t in sorted(times):
        if after is not None and t < after:
            continue
        if before is not None and t > before:
            break
        v1 = normalize(sig_a[t], width_a)
        v2 = normalize(sig_b[t], width_b)
        if v1 == v2:
            continue
        return (t, v1 or "", v2 or "", key)
    return None


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Print the first difference between two VCD files")
    parser.add_argument("file1", metavar="VCD1", help="first file to compare")
    parser.add_argument("file2", metavar="VCD2", help="second file to compare")
    parser.add_argument("--top1", metavar="INSTPATH", help="instance in first file to compare")
    parser.add_argument("--top2", metavar="INSTPATH", help="instance in second file to compare")
    parser.add_argument(
        "-f",
        "--filter",
        metavar="REGEX",
        action="append",
        default=[],
        help="only compare signals matching a regex",
    )
    parser.add_argument(
        "-i",
        "--ignore",
        metavar="REGEX",
        action="append",
        default=[],
        help="ignore signals matching a regex",
    )
    parser.add_argument("-l", "--list", action="store_true", help="list signals and exit")
    parser.add_argument("-v", "--verbose", action="store_true", help="verbose output")
    parser.add_argument("-a", "--after", type=int, help="only compare after time")
    parser.add_argument("-b", "--before", type=int, help="only compare before time")
    args = parser.parse_args(argv)

    path1 = Path(args.file1)
    path2 = Path(args.file2)

    hdr1 = parse_vcd_header(path1)
    hdr2 = parse_vcd_header(path2)
    infoln(args.verbose, f"{len(hdr1.signals)} signals in first file")
    infoln(args.verbose, f"{len(hdr2.signals)} signals in second file")

    filtered1 = filter_signals(hdr1.signals, args.top1)
    filtered2 = filter_signals(hdr2.signals, args.top2)
    if args.top1 is not None:
        infoln(args.verbose, f"{len(filtered1)} signals under `{args.top1}` in first file")
    if args.top2 is not None:
        infoln(args.verbose, f"{len(filtered2)} signals under `{args.top2}` in second file")

    common_entries: list[dict[str, Any]] = []
    for key, sig1 in filtered1.items():
        sig2 = filtered2.get(key)
        if sig2 is not None:
            common_entries.append({"key": key, "kind": "direct", "sig1": sig1, "sig2": sig2})

    ranges1, bits1 = index_by_base(filtered1)
    ranges2, bits2 = index_by_base(filtered2)
    direct_keys = {e["key"] for e in common_entries}

    def add_bus_entry(base: str, msb: int, lsb: int, range_sig: str, bit_sigs: dict[int, str], which_range: str) -> None:
        key = f"{base}[{msb}:{lsb}]"
        if key in direct_keys:
            return
        common_entries.append(
            {
                "key": key,
                "kind": "bus",
                "msb": msb,
                "lsb": lsb,
                "which_range": which_range,
                "range_sig": range_sig,
                "bit_sigs": {int(k): v for k, v in bit_sigs.items()},
            }
        )

    for base, (msb, lsb, full_range) in ranges1.items():
        if base not in bits2:
            continue
        if not has_bits(bits2[base], msb, lsb):
            continue
        add_bus_entry(base, msb, lsb, full_range, bits2[base], which_range="file1")

    for base, (msb, lsb, full_range) in ranges2.items():
        if base not in bits1:
            continue
        if not has_bits(bits1[base], msb, lsb):
            continue
        add_bus_entry(base, msb, lsb, full_range, bits1[base], which_range="file2")

    common_entries.sort(key=lambda e: e["key"])
    infoln(args.verbose, f"{len(common_entries)} comparable signal entries")

    for filt in args.filter:
        rx = re.compile(filt)
        common_entries = [e for e in common_entries if rx.search(e["key"])]

    for ign in args.ignore:
        rx = re.compile(ign)
        common_entries = [e for e in common_entries if not rx.search(e["key"])]

    if args.filter or args.ignore:
        infoln(args.verbose, f"{len(common_entries)} filtered and unignored entries")

    if args.list:
        for e in common_entries:
            print(e["key"])
        return 0

    if not common_entries:
        sys.stderr.write("no common signals between input files\n")
        return 2

    need1: set[str] = set()
    need2: set[str] = set()
    for e in common_entries:
        if e["kind"] == "direct":
            need1.add(e["sig1"])
            need2.add(e["sig2"])
            continue
        if e["which_range"] == "file1":
            need1.add(e["range_sig"])
            need2.update(e["bit_sigs"].values())
        else:
            need1.update(e["bit_sigs"].values())
            need2.add(e["range_sig"])

    infoln(args.verbose, "Reading first file")
    vcd1 = parse_vcd_values(path1, hdr1, need1)
    infoln(args.verbose, "Reading second file")
    vcd2 = parse_vcd_values(path2, hdr2, need2)

    earliest: list[tuple[int, str, str, str]] = []
    for entry in common_entries:
        key = entry["key"]
        infoln(args.verbose, f"Comparing {key}")

        mismatch: Optional[tuple[int, str, str, str]]
        if entry["kind"] == "direct":
            s1 = vcd1.signals[entry["sig1"]]
            s2 = vcd2.signals[entry["sig2"]]
            mismatch = compare_at_times(key, s1, s1.size, s2, s2.size, args.after, args.before)
        else:
            msb = int(entry["msb"])
            lsb = int(entry["lsb"])
            width = abs(msb - lsb) + 1
            if entry["which_range"] == "file1":
                s1 = vcd1.signals[entry["range_sig"]]
                bits = {idx: vcd2.signals[name] for idx, name in entry["bit_sigs"].items()}
                s2 = BusSignal(bits, msb, lsb)
            else:
                bits = {idx: vcd1.signals[name] for idx, name in entry["bit_sigs"].items()}
                s1 = BusSignal(bits, msb, lsb)
                s2 = vcd2.signals[entry["range_sig"]]
            mismatch = compare_at_times(key, s1, getattr(s1, "size", width), s2, getattr(s2, "size", width), args.after, args.before)

        if mismatch is None:
            continue
        t, v1, v2, name = mismatch
        if earliest and t < earliest[0][0]:
            earliest = []
        if not earliest or t == earliest[0][0]:
            earliest.append((t, v1, v2, name))

    for t, sig1, sig2, name in earliest:
        print(f"{t}  {binary_string_to_hex(sig1)}  {binary_string_to_hex(sig2)}  {name}")
    return 1 if earliest else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))


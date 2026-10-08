#!/usr/bin/env python3
"""gen-address-golden.py - golden table for Socket.Address (plans/eco-system-sockets.md S1 step 2).

Writes tests/tests/AddressGolden.elm (relative to system-kernel-cpp/) from the fixed input list
below, which has valid and invalid inputs for every rule of the plan's Appendix D.1.

  * Validity: Python's `ipaddress` on the text before the first `%` (IPv4Address, then
    IPv6Address), plus the D.1 scope grammar for what follows `%`: 1-15 characters from
    [A-Za-z0-9_.-], allowed on IPv6 addresses only.
  * Canonical text (`toString`): `ipaddress`'s `compressed` form, except that IPv4-mapped
    addresses (::ffff:0:0/96) are printed `::ffff:` + dotted quad by this script (Python 3.11
    prints them in hex), then `%scope`.
  * Octets: `packed`.
  * Predicates (`isLoopback`, `isUnspecified`, `isIPv4Mapped`) and `unmapIPv4` are computed here
    from the octets, per D.1, not by `ipaddress` (whose definitions differ, e.g. Python says
    ::ffff:127.0.0.1 is not loopback).

The output records the Python version used. Regenerate from system-kernel-cpp/ with:

    python3 scripts/gen-address-golden.py [outFile]
"""

import ipaddress
import os
import re
import sys

SCOPE_RE = re.compile(r"[A-Za-z0-9_.-]{1,15}")

INPUTS = [
    # --- IPv4: valid
    "0.0.0.0",
    "127.0.0.1",
    "127.255.255.254",
    "126.255.255.255",
    "128.0.0.1",
    "1.2.3.4",
    "10.0.0.255",
    "192.168.1.10",
    "255.255.255.255",
    # --- IPv4: invalid
    "1.2.3",
    "1.2.3.4.5",
    "01.2.3.4",
    "1.02.3.4",
    "1.2.3.00",
    "00.0.0.0",
    "256.0.0.1",
    "1.2.3.256",
    "999.0.0.0",
    "1234.1.1.1",
    "1.2.3.-1",
    "+1.2.3.4",
    "0x1.2.3.4",
    "1.2.3.a",
    "1..3.4",
    "1.2.3.",
    ".1.2.3",
    "1.2.3.4.",
    "1,2,3,4",
    "١.2.3.4",
    "1.2.3.4%eth0",
    "1.2.3.4%1",
    # --- empty, whitespace, names
    "",
    " ",
    "\t",
    "localhost",
    " 1.2.3.4",
    "1.2.3.4 ",
    "1.2.3.4\n",
    # --- IPv6: valid, `::` placement
    "::",
    "::0",
    "0::0",
    "::1",
    "::0:1",
    "1::",
    "1::8",
    "0:0:0:0:0:0:0:0",
    "0:0:0:0:0:0:0:1",
    "1:2:3:4:5:6:7:8",
    "1:2:3:4:5:6:7::",
    "::2:3:4:5:6:7:8",
    "1::2:3:4:5:6:7",
    "1:2:3:4:5:6::8",
    "0001:0002::0003",
    # --- IPv6: valid, printing rules
    "2001:db8::1",
    "2001:DB8::1",
    "2001:0db8:0000:0000:0000:0000:0000:0001",
    "2001:db8:0:0:1:0:0:1",
    "2001:db8::1:0:0:1",
    "2001:0:0:1:0:0:0:1",
    "2001:db8:0:1:1:1:1:1",
    "1:0:2:0:3:0:4:0",
    "0:1:2:3:4:5:6:7",
    "1:2:3:4:5:6:7:0",
    "0:0:1:2:3:4:5:6",
    "1:2:3:4:5:6:0:0",
    "1:0:0:2:0:0:0:3",
    "ff02::1",
    "FFFF::",
    "abcd:ef01:2345:6789:ABCD:EF01:2345:6789",
    "Fe80::A:b:C:d",
    # --- IPv6: valid, embedded IPv4 (mapped, compatible, other)
    "::ffff:127.0.0.1",
    "::FFFF:7f00:1",
    "::ffff:127.255.0.1",
    "::ffff:0.0.0.0",
    "::ffff:0:0",
    "::ffff:192.168.1.1",
    "::ffff:128.0.0.1",
    "::ffff:1:2",
    "0:0:0:0:0:ffff:127.0.0.1",
    "0:0:0:0:0:FFFF:0a00:0001",
    "::fffe:1.2.3.4",
    "::127.0.0.1",
    "::1.2.3.4",
    "::0.0.0.1",
    "64:ff9b::1.2.3.4",
    "1:2:3:4:5:6:1.2.3.4",
    "::1:ffff:1.2.3.4",
    # --- IPv6: valid, scopes
    "fe80::1%eth0",
    "fe80::1%1",
    "fe80::1%en0.100",
    "fe80::1%a_b-c.d",
    "fe80::1%ETH0",
    "fe80::1%123456789012345",
    "::1%lo",
    "::%lo",
    "::ffff:127.0.0.1%lo",
    "::ffff:1.2.3.4%2",
    # --- IPv6: invalid, structure
    ":",
    ":::",
    "::::",
    "1:2:3:4:5:6:7",
    "1:2:3:4:5:6:7:8:9",
    "1::2::3",
    "::1::",
    "1:2:3:4:5:6:7:8::",
    "::1:2:3:4:5:6:7:8",
    "1:2:3:4::5:6:7:8",
    ":1::",
    "::1:",
    "1:",
    ":1",
    "1:::2",
    ":1:2:3:4:5:6:7:8",
    "1:2:3:4:5:6:7:8:",
    "[::1]",
    # --- IPv6: invalid, groups
    "12345::",
    "::12345",
    "g::1",
    "::g",
    "0x1::",
    "::-1",
    "::+1",
    "1:2:3:4:5:6:7:8 ",
    " ::1",
    "::1 ",
    ":: 1",
    "::١",
    # --- IPv6: invalid, embedded IPv4
    "1.2.3.4::",
    "::1.2.3",
    "::01.2.3.4",
    "::256.0.0.1",
    "::1.2.3.4.5",
    "::1.2.3.4:5",
    "::1.2.3.4:1.2.3.4",
    "1:2:3:4:5:6:7:1.2.3.4",
    "1:2:3:4:5:6:7:8:1.2.3.4",
    "::ffff:1.2.3.4.",
    # --- IPv6: invalid, scopes
    "::1%",
    "::1%%eth0",
    "::1%eth0%1",
    "::1%eth 0",
    "::1%1234567890123456",
    "::1%eth0/",
    "::1%eth0:1",
    "::1%é",
    "fe80::1%eth0 ",
    "%eth0",
    "%",
    "::ffff:1.2.3.4%",
    "1:2:3:4:5:6:7:8%",
]


def parse(text):
    """( address, scope ) or None, per the module docstring."""
    if "%" in text:
        body, _, scope = text.partition("%")
        if not SCOPE_RE.fullmatch(scope):
            return None
        try:
            return ipaddress.IPv6Address(body), scope
        except ValueError:
            return None
    try:
        return ipaddress.IPv4Address(text), ""
    except ValueError:
        pass
    try:
        return ipaddress.IPv6Address(text), ""
    except ValueError:
        return None


MAPPED_PREFIX = [0] * 10 + [255, 255]
LOOPBACK6 = [0] * 15 + [1]


def dotted(octets):
    return ".".join(str(o) for o in octets)


def expected(address, scope):
    octets = list(address.packed)
    if address.version == 4:
        canonical = dotted(octets)
        mapped = False
        loop = octets[0] == 127
        unmapped = canonical
    else:
        mapped = octets[:12] == MAPPED_PREFIX
        body = "::ffff:" + dotted(octets[12:]) if mapped else address.compressed
        canonical = body + ("%" + scope if scope else "")
        loop = (mapped and octets[12] == 127) or octets == LOOPBACK6
        unmapped = dotted(octets[12:]) if mapped else canonical
    return {
        "canonical": canonical,
        "octets": octets,
        "family": address.version,
        "isLoopback": loop,
        "isUnspecified": all(o == 0 for o in octets),
        "isIPv4Mapped": mapped,
        "unmapped": unmapped,
    }


def elm_string(s):
    out = []
    for ch in s:
        code = ord(ch)
        if ch == "\\":
            out.append("\\\\")
        elif ch == '"':
            out.append('\\"')
        elif ch == "\n":
            out.append("\\n")
        elif ch == "\t":
            out.append("\\t")
        elif ch == "\r":
            out.append("\\r")
        elif code < 0x20 or code > 0x7E:
            out.append("\\u{%04X}" % code)
        else:
            out.append(ch)
    return '"' + "".join(out) + '"'


def elm_bool(b):
    return "True" if b else "False"


def elm_case(text):
    parsed = parse(text)
    if parsed is None:
        return "{ input = %s, expected = Nothing }" % elm_string(text)
    e = expected(*parsed)
    return (
        "{ input = %s\n"
        "      , expected =\n"
        "            Just\n"
        "                { canonical = %s\n"
        "                , octets = [ %s ]\n"
        "                , family = %d\n"
        "                , isLoopback = %s\n"
        "                , isUnspecified = %s\n"
        "                , isIPv4Mapped = %s\n"
        "                , unmapped = %s\n"
        "                }\n"
        "      }"
    ) % (
        elm_string(text),
        elm_string(e["canonical"]),
        ", ".join(str(o) for o in e["octets"]),
        e["family"],
        elm_bool(e["isLoopback"]),
        elm_bool(e["isUnspecified"]),
        elm_bool(e["isIPv4Mapped"]),
        elm_string(e["unmapped"]),
    )


def main():
    if len(INPUTS) != len(set(INPUTS)):
        sys.exit("gen-address-golden: duplicate inputs")
    here = os.path.dirname(os.path.abspath(__file__))
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.normpath(os.path.join(here, "..", "tests", "tests", "AddressGolden.elm"))
    version = sys.version.split()[0]
    cases = "\n    , ".join(elm_case(t) for t in INPUTS)
    valid = sum(1 for t in INPUTS if parse(t) is not None)
    source = f'''module AddressGolden exposing (Case, Expected, cases, pythonVersion)

{{-| GENERATED FILE — do not edit.

Golden table for Socket.Address ({len(INPUTS)} inputs, {valid} valid), produced by
scripts/gen-address-golden.py with Python {version} (`ipaddress` for validity and the compressed
IPv6 text; IPv4-mapped printing, octets and predicates computed by the script per
plans/eco-system-sockets.md Appendix D.1).

Regenerate from system-kernel-cpp/ with:

    python3 scripts/gen-address-golden.py

-}}


{{-| The Python version that produced the table.
-}}
pythonVersion : String
pythonVersion =
    {elm_string(version)}


{{-| `family` is 4 or 6; `unmapped` is `toString (unmapIPv4 address)`.
-}}
type alias Expected =
    {{ canonical : String
    , octets : List Int
    , family : Int
    , isLoopback : Bool
    , isUnspecified : Bool
    , isIPv4Mapped : Bool
    , unmapped : String
    }}


{{-| `expected` is `Nothing` for an input that is not a valid address.
-}}
type alias Case =
    {{ input : String
    , expected : Maybe Expected
    }}


cases : List Case
cases =
    [ {cases}
    ]
'''
    with open(out, "w", encoding="utf-8") as f:
        f.write(source)
    print(f"gen-address-golden: wrote {out} ({len(INPUTS)} cases, {valid} valid, Python {version})")


if __name__ == "__main__":
    main()

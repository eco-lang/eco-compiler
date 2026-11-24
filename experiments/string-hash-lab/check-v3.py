#!/usr/bin/env python3
"""check-v3.py: the lab's copy of v3 against the independent reference (v3ref.py), on the Strings
`hashlab v3vec` prints."""
import subprocess, sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from v3ref import string_hash
out = subprocess.run([sys.argv[1], "v3vec"], capture_output=True, text=True, check=True).stdout
n = bad = 0
for line in out.splitlines():
    if not line.startswith("v3 "): continue
    _, k, ln, h = line.split(); k, ln = int(k), int(ln)
    s = ''.join(chr(0x20 + (i * 7 + ln) % 0x5F) if k == 0 else chr(0x4E00 + (i * 13 + ln) % 3000) for i in range(ln))
    n += 1; bad += string_hash(s) != int(h)
print(f"v3 copy vs v3ref.py: {n} Strings, {bad} mismatches")
sys.exit(1 if bad else 0)

#!/bin/sh
# WebSocket client masking keys and the Sec-WebSocket-Key come from the system CSPRNG (`RAND_bytes`, or
# `BCryptGenRandom` on Windows); a failing RNG aborts with a clear message, never falls back to a predictable
# generator. A runtime test cannot make the RNG fail, so this fails while any WebSocket source names `mt19937`
# or `random_device`. Exit 0 = clean, 1 = found.
root=${1:-.}
dir="$root/system-kernel-cpp/src/eco-system/WebSocket"
[ -d "$dir" ] || { echo "no $dir"; exit 2; }
hits=$(grep -rnE 'mt19937|random_device' "$dir")
if [ -n "$hits" ]; then
    echo "non-cryptographic RNG fallback in the WebSocket sources:"
    echo "$hits"
    exit 1
fi
exit 0

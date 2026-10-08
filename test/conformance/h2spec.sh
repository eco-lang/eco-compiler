#!/usr/bin/env bash
# h2spec 2.6.0 against Http.Server's HTTP/2 (examples/system/src/WsEchoServer.elm with TLS and
# --http2), compared with the baseline in test/conformance/h2spec-baseline.txt.
#
# LOCAL ONLY: never run this in CI (plans/eco-system-websockets.md W18, Appendix F). It downloads
# h2spec to /tmp. h2spec is a baseline to compare, not an all-green gate: nghttp2 (and Node) fail
# some of its strict cases on purpose (see the baseline file).
#
# Usage: test/conformance/h2spec.sh [--backend native|js|both] [--no-build]
#
# Environment: ECO_BUILD_DIR (default <repo>/build; needs the guida and eco-boot-native targets),
# ECO_H2SPEC_TOOLS (default /tmp/eco-h2spec-tools), ECO_H2SPEC_WORK (default /tmp/eco-h2spec-run),
# H2SPEC_PORT (default 9443).
#
# Exit status: 0 when every backend scored at least its baseline, 1 otherwise.

set -euo pipefail
. "$(dirname "$0")/common.sh"

TOOLS=${ECO_H2SPEC_TOOLS:-/tmp/eco-h2spec-tools}
WORK=${ECO_H2SPEC_WORK:-/tmp/eco-h2spec-run}
PORT=${H2SPEC_PORT:-9443}
BASELINE=$CONF_DIR/h2spec-baseline.txt
BACKENDS="native js"
BUILD_PROGRAMS=1

while [ $# -gt 0 ]; do
    case $1 in
    --backend) [ "$2" = both ] && BACKENDS="native js" || BACKENDS=$2; shift 2 ;;
    --no-build) BUILD_PROGRAMS=0; shift ;;
    -h | --help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument $1 (see --help)" ;;
    esac
done

H2SPEC_URL=https://github.com/summerwind/h2spec/releases/download/v2.6.0/h2spec_linux_amd64.tar.gz
H2SPEC_SHA=157ee0de702e01ad40e752dbf074b366027e550c8e7504f9450da2809e279318

if [ ! -x "$TOOLS/h2spec" ]; then
    fetch "$H2SPEC_URL" "$H2SPEC_SHA" "$TOOLS/dl/h2spec_linux_amd64.tar.gz"
    tar -C "$TOOLS" -xzf "$TOOLS/dl/h2spec_linux_amd64.tar.gz" h2spec
fi
log "using $("$TOOLS/h2spec" --version | head -1)"

BIN=$WORK/bin
[ "$BUILD_PROGRAMS" = 1 ] && build_program WsEchoServer ws-echo-server "$BIN" "$BACKENDS"
write_test_tls "$WORK/tls"

PID=''
trap 'stop_pid "$PID"' EXIT

status=0
for backend in $BACKENDS; do
    port_free "$PORT" || die "port $PORT is in use"
    # shellcheck disable=SC2046
    $(program_cmd "$backend" "$BIN" ws-echo-server) "$PORT" --tls "$WORK/tls/cert.pem" "$WORK/tls/key.pem" --http2 \
        >"$WORK/server-$backend.log" 2>&1 &
    PID=$!
    wait_port "$PORT" 60 || { cat "$WORK/server-$backend.log" >&2; die "WsEchoServer ($backend) did not start"; }
    log "h2spec against WsEchoServer ($backend) on port $PORT"
    "$TOOLS/h2spec" -h 127.0.0.1 -p "$PORT" -t -k -j "$WORK/h2spec-$backend.xml" >"$WORK/h2spec-$backend.txt" 2>&1 || true
    stop_pid "$PID"
    PID=''

    # "146 tests, 136 passed, 1 skipped, 9 failed"
    line=$(grep -aE '^[0-9]+ tests, [0-9]+ passed' "$WORK/h2spec-$backend.txt" | tail -1 || true)
    [ -n "$line" ] || { tail -20 "$WORK/h2spec-$backend.txt" >&2; die "h2spec ($backend) printed no result"; }
    total=$(echo "$line" | sed -E 's/^([0-9]+) tests.*/\1/')
    passed=$(echo "$line" | sed -E 's/^[0-9]+ tests, ([0-9]+) passed.*/\1/')
    base=$(awk -v b="$backend" '$1 == b { print $2 }' "$BASELINE")
    basePassed=${base%/*}
    echo "h2spec $backend: $passed/$total ($line); baseline ${base:-none}"
    python3 -I - "$WORK/h2spec-$backend.xml" <<'EOF'
import html, re, sys
# The JUnit file can hold raw frame bytes (not well-formed XML): scan it with a pattern.
text = open(sys.argv[1], 'rb').read().decode('latin-1')
for m in re.finditer(r'<testcase package="([^"]*)" classname="([^"]*)"[^>]*>(.*?)</testcase>', text, re.S):
    if '<failure' in m.group(3) or '<error' in m.group(3):
        print('  failed: %s %s' % (m.group(1), html.unescape(m.group(2))))
EOF
    if [ -n "$base" ] && [ "$passed" -lt "$basePassed" ]; then
        echo "h2spec $backend: WORSE than the baseline ($passed < $basePassed)"
        status=1
    fi
done
log "outputs: $WORK/h2spec-<backend>.txt"
exit $status

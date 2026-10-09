#!/usr/bin/env bash
# Autobahn|Testsuite 25.10.1 against eco/system's WebSocket server and client.
#
# LOCAL ONLY: never run this in CI (plans/eco-system-websockets.md W18, Appendix F). It downloads
# PyPy 2.7, builds OpenSSL 1.1.1w and installs autobahntestsuite under /tmp (once, about five
# minutes), and a full run takes tens of minutes.
#
# Modes:
#   server  wstest -m fuzzingclient tests examples/system/src/WsEchoServer.elm (Http.Server +
#           Http.Server.upgradeRequest), one run per backend and per server variant.
#   client  wstest -m fuzzingserver tests WebSocket.connect, driven by
#           examples/system/src/WsAutobahnClient.elm, one run per backend.
#
# Usage: test/conformance/autobahn.sh [options]
#   --mode server|client|both     (default both)
#   --backend native|js|both      (default both)
#   --cases LIST                  comma-separated case patterns, e.g. "1.*,12.1.*" (default "*")
#   --exclude LIST                comma-separated case patterns to skip (default none)
#   --variants LIST               comma-separated, of:
#                                   default   compression as the defaults (on, no context takeover)
#                                   takeover  context takeover allowed (server --context-takeover);
#                                             server only; runs only 12.* and 13.* unless --cases
#                                   off       no compression (--no-compression); runs only 12.* and
#                                             13.* unless --cases (expect UNIMPLEMENTED there)
#                                 (default "default,takeover" for servers, "default" for clients)
#   --no-split                    one process for all the cases of a run (by default every
#                                 case group (1.* ... 10.*, and 12.1.* ... 13.7.*) gets a fresh
#                                 server or fuzzingserver + client, so a crash or a leak stays in
#                                 its group)
#                                 Since plans/large-object-space.md (2026-10-09) --no-split passes natively in
#                                 one process (server and client peak ~0.47 GB; before: 11.6 GB, killed).
#   --no-build                    reuse the programs built by an earlier run
#   --install-only                install the tools and stop
#
# Environment: ECO_BUILD_DIR (default <repo>/build; needs the guida and eco-boot-native targets),
# ECO_AUTOBAHN_TOOLS (default /tmp/eco-autobahn-tools), ECO_AUTOBAHN_WORK (default
# /tmp/eco-autobahn-run), AUTOBAHN_PORT (default 9001), WSTEST (use an existing wstest).
#
# Output: reports under $ECO_AUTOBAHN_WORK/reports/<mode>-<backend>-<variant>/ (index.html,
# index.json; one subdirectory per case group) and a summary of every case that is not OK or
# INFORMATIONAL. The results are informational: the exit status is 0 unless a program under test
# crashed (or a client exited with an error) or wstest failed, which the summary also reports.

set -euo pipefail
set -f   # case patterns such as 1.* are words, never file globs
. "$(dirname "$0")/common.sh"

TOOLS=${ECO_AUTOBAHN_TOOLS:-/tmp/eco-autobahn-tools}
WORK=${ECO_AUTOBAHN_WORK:-/tmp/eco-autobahn-run}
PORT=${AUTOBAHN_PORT:-9001}

MODE=both
BACKENDS="native js"
CASES='*'
CASES_GIVEN=0
EXCLUDE=''
VARIANTS=''
BUILD_PROGRAMS=1
INSTALL_ONLY=0
SPLIT=1

while [ $# -gt 0 ]; do
    case $1 in
    --mode) MODE=$2; shift 2 ;;
    --backend) [ "$2" = both ] && BACKENDS="native js" || BACKENDS=$2; shift 2 ;;
    --cases) CASES=$2; CASES_GIVEN=1; shift 2 ;;
    --exclude) EXCLUDE=$2; shift 2 ;;
    --variants) VARIANTS=$2; shift 2 ;;
    --no-build) BUILD_PROGRAMS=0; shift ;;
    --no-split) SPLIT=0; shift ;;
    --install-only) INSTALL_ONLY=1; shift ;;
    -h | --help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument $1 (see --help)" ;;
    esac
done

# --- Tools (Appendix F) ---------------------------------------------------------------------------

PYPY_URL=https://downloads.python.org/pypy/pypy2.7-v7.3.23-linux64.tar.gz
PYPY_SHA=f4c021b928e7d5f4f7604c389dc992c2bdd8240da758a95fc88ef61a8a7e2ea5
OPENSSL_URL=https://github.com/openssl/openssl/releases/download/OpenSSL_1_1_1w/openssl-1.1.1w.tar.gz
OPENSSL_SHA=cf3098950cb4d853ad95c0841f1f9c6d3dc102dccfcacd521d93925208b76ac8

install_tools() {
    local pypy=$TOOLS/pypy/bin/pypy
    if [ ! -x "$pypy" ]; then
        fetch "$PYPY_URL" "$PYPY_SHA" "$TOOLS/dl/pypy2.7-v7.3.23-linux64.tar.gz"
        rm -rf "$TOOLS/pypy" "$TOOLS/pypy2.7-v7.3.23-linux64"
        tar -C "$TOOLS" -xzf "$TOOLS/dl/pypy2.7-v7.3.23-linux64.tar.gz"
        mv "$TOOLS/pypy2.7-v7.3.23-linux64" "$TOOLS/pypy"
    fi
    if [ ! -f "$TOOLS/openssl/lib/libcrypto.a" ]; then
        # cryptography 3.3.2 (what autobahntestsuite's pyOpenSSL needs) fails against the system's
        # OpenSSL 3 (FIPS_mode): link it statically with OpenSSL 1.1.1.
        fetch "$OPENSSL_URL" "$OPENSSL_SHA" "$TOOLS/dl/openssl-1.1.1w.tar.gz"
        rm -rf "$TOOLS/openssl-src"
        mkdir -p "$TOOLS/openssl-src"
        tar -C "$TOOLS/openssl-src" --strip-components=1 -xzf "$TOOLS/dl/openssl-1.1.1w.tar.gz"
        log "building OpenSSL 1.1.1w (static) under $TOOLS/openssl"
        (cd "$TOOLS/openssl-src" &&
            ./config no-shared -fPIC --prefix="$TOOLS/openssl" --openssldir="$TOOLS/openssl/ssl" &&
            make -j"$(nproc)" build_libs && make install_dev) >"$TOOLS/openssl-build.log" 2>&1 \
            || { tail -30 "$TOOLS/openssl-build.log" >&2; die "OpenSSL build failed"; }
        rm -rf "$TOOLS/openssl-src"
    fi
    if ! "$TOOLS/pypy/bin/wstest" -a >/dev/null 2>&1; then
        log "installing autobahntestsuite 25.10.1 into $TOOLS/pypy"
        (
            set -e
            "$pypy" -m ensurepip
            "$pypy" -m pip install 'pip<21'
            "$pypy" -m pip install typing incremental==16.10.1 pycparser
            CFLAGS="-I$TOOLS/openssl/include" LDFLAGS="-L$TOOLS/openssl/lib" \
                "$pypy" -m pip install --no-binary cryptography cryptography==3.3.2
            "$pypy" -m pip install autobahntestsuite==25.10.1
        ) >"$TOOLS/pip.log" 2>&1 || { tail -30 "$TOOLS/pip.log" >&2; die "pip install failed (see $TOOLS/pip.log)"; }
        "$TOOLS/pypy/bin/wstest" -a >/dev/null 2>&1 || die "wstest does not run (see $TOOLS/pip.log)"
    fi
    WSTEST=$TOOLS/pypy/bin/wstest
}

if [ -n "${WSTEST:-}" ]; then
    "$WSTEST" -a >/dev/null 2>&1 || die "WSTEST=$WSTEST does not run"
else
    install_tools
fi
log "using $("$WSTEST" -a 2>&1 | tr '\n' ' ')($WSTEST)"
[ "$INSTALL_ONLY" = 1 ] && exit 0

# --- Programs -------------------------------------------------------------------------------------

BIN=$WORK/bin
if [ "$BUILD_PROGRAMS" = 1 ]; then
    case $MODE in server | both) build_program WsEchoServer ws-echo-server "$BIN" "$BACKENDS" ;; esac
    case $MODE in client | both) build_program WsAutobahnClient ws-autobahn-client "$BIN" "$BACKENDS" ;; esac
fi

# --- Runs -----------------------------------------------------------------------------------------

json_list() { # "a,b" -> ["a", "b"]
    local out='' item
    IFS=, read -ra items <<<"$1"
    for item in "${items[@]}"; do
        [ -n "$item" ] && out="$out${out:+, }\"$item\""
    done
    echo "[$out]"
}

cases_for() { # variant -> case list
    if [ "$1" = default ] || [ "$CASES_GIVEN" = 1 ]; then echo "$CASES"; else echo '12.*,13.*'; fi
}

groups_for() { # variant -> the case lists of its runs, one per word
    local cases
    cases=$(cases_for "$1")
    if [ "$SPLIT" = 0 ]; then
        echo "$cases"
    elif [ "$cases" = '*' ]; then
        echo "1.* 2.* 3.* 4.* 5.* 6.* 7.* 9.* 10.* $SPLIT_DEFLATE"
    elif [ "$cases" = '12.*,13.*' ]; then
        echo "$SPLIT_DEFLATE"
    else
        echo "$cases" | tr , ' '
    fi
}

# The permessage-deflate groups are split per subsection (12.1.* ... 13.7.*): they move the most
# data, and a native program that grows (plans/eco-system-websockets.md R7) stays in one of them.
SPLIT_DEFLATE='12.1.* 12.2.* 12.3.* 12.4.* 12.5.* 13.1.* 13.2.* 13.3.* 13.4.* 13.5.* 13.6.* 13.7.*'

label() { # "12.*" -> "12", "*" -> "all"
    local l
    l=$(echo "$1" | tr -c '0-9A-Za-z\n' _ | sed 's/_*$//')
    echo "${l:-all}"
}

PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do stop_pid "$p"; done; }
trap cleanup EXIT

REPORTS=()   # "name|index.json"
PROBLEMS=()  # one line each

run_server() { # backend variant
    local backend=$1 variant=$2 flags='' name="server-$1-$2" group
    case $variant in
    default) ;;
    takeover) flags=--context-takeover ;;
    off) flags=--no-compression ;;
    *) die "unknown variant $variant" ;;
    esac
    rm -rf "$WORK/reports/$name"
    for group in $(groups_for "$variant"); do
        local g out base pid
        g=$(label "$group")
        out=$WORK/reports/$name/$g
        base=$WORK/logs/$name.$g
        mkdir -p "$out" "$WORK/logs"
        port_free "$PORT" || die "port $PORT is in use"
        # shellcheck disable=SC2046
        $(program_cmd "$backend" "$BIN" ws-echo-server) "$PORT" $flags >"$base.server.log" 2>&1 &
        pid=$!
        PIDS+=("$pid")
        wait_port "$PORT" 60 || { cat "$base.server.log" >&2; die "WsEchoServer ($backend) did not start"; }
        cat >"$base.json" <<EOF
{
  "outdir": "$out",
  "servers": [{ "agent": "eco-$backend-$variant", "url": "ws://127.0.0.1:$PORT" }],
  "cases": $(json_list "$group"),
  "exclude-cases": $(json_list "$EXCLUDE"),
  "exclude-agent-cases": {}
}
EOF
        log "fuzzingclient: $name, cases $group"
        (cd "$WORK" && "$WSTEST" -m fuzzingclient -s "$base.json") >"$base.wstest.log" 2>&1 \
            || PROBLEMS+=("$name $group: wstest failed (see $base.wstest.log)")
        if ! alive "$pid"; then
            PROBLEMS+=("$name $group: WsEchoServer exited during the run: $(grep -a -m1 -iE 'assert|abort|error|exception' "$base.server.log" | cut -c1-200) (see $base.server.log)")
        fi
        stop_pid "$pid"
        REPORTS+=("$name|$out/index.json")
    done
}

alive() { # a child that exited is a zombie until waited for: kill -0 still succeeds
    kill -0 "$1" 2>/dev/null && [ "$(ps -o stat= -p "$1" 2>/dev/null | cut -c1)" != Z ]
}

run_client() { # backend variant
    local backend=$1 variant=$2 flags='' name="client-$1-$2" group
    case $variant in
    default) ;;
    off) flags=--no-compression ;;
    takeover) log "variant takeover applies to servers only: skipped for the client"; return 0 ;;
    *) die "unknown variant $variant" ;;
    esac
    rm -rf "$WORK/reports/$name"
    for group in $(groups_for "$variant"); do
        local g out base pid status=0
        g=$(label "$group")
        out=$WORK/reports/$name/$g
        base=$WORK/logs/$name.$g
        mkdir -p "$out" "$WORK/logs"
        port_free "$PORT" || die "port $PORT is in use"
        cat >"$base.json" <<EOF
{
  "url": "ws://127.0.0.1:$PORT",
  "outdir": "$out",
  "cases": $(json_list "$group"),
  "exclude-cases": $(json_list "$EXCLUDE"),
  "exclude-agent-cases": {}
}
EOF
        (cd "$WORK" && exec "$WSTEST" -m fuzzingserver -s "$base.json") >"$base.wstest.log" 2>&1 &
        pid=$!
        PIDS+=("$pid")
        wait_port "$PORT" 60 || { cat "$base.wstest.log" >&2; die "wstest fuzzingserver did not start"; }
        log "fuzzingserver: $name, cases $group"
        # shellcheck disable=SC2046
        $(program_cmd "$backend" "$BIN" ws-autobahn-client) "ws://127.0.0.1:$PORT" "eco-$backend-$variant" $flags \
            >"$base.client.log" 2>&1 || status=$?
        if [ "$status" != 0 ]; then
            PROBLEMS+=("$name $group: WsAutobahnClient exited with status $status: $(grep -a -m1 -iE 'assert|abort|error|ws-autobahn-client: [a-z]' "$base.client.log" | cut -c1-200) (see $base.client.log)")
        fi
        stop_pid "$pid"
        REPORTS+=("$name|$out/index.json")
    done
}

mkdir -p "$WORK"
case $MODE in
server | both)
    for backend in $BACKENDS; do
        for variant in $(echo "${VARIANTS:-default,takeover}" | tr , ' '); do run_server "$backend" "$variant"; done
    done
    ;;
esac
case $MODE in
client | both)
    for backend in $BACKENDS; do
        for variant in $(echo "${VARIANTS:-default}" | tr , ' '); do run_client "$backend" "$variant"; done
    done
    ;;
esac

# --- Summary --------------------------------------------------------------------------------------

python3 -I - "${REPORTS[@]}" <<'EOF'
import collections, json, os, sys

def key(case):
    return [int(x) for x in case.split('.')]

runs = collections.OrderedDict()   # name -> {agent: {case: result}}
missing = []
for arg in sys.argv[1:]:
    name, path = arg.split('|', 1)
    merged = runs.setdefault(name, {})
    if not os.path.exists(path):
        missing.append('%s: no report %s' % (name, path))
        continue
    with open(path) as f:
        for agent, cases in json.load(f).items():
            merged.setdefault(agent, {}).update(cases)

for name, agents in runs.items():
    for agent, cases in sorted(agents.items()):
        behavior = collections.Counter(v['behavior'] for v in cases.values())
        close = collections.Counter(v['behaviorClose'] for v in cases.values())
        print('%s (agent %s): %d cases; behavior %s; close %s' % (
            name, agent, len(cases), dict(sorted(behavior.items())), dict(sorted(close.items()))))
        bad = collections.defaultdict(list)
        for case, v in cases.items():
            b, c = v['behavior'], v['behaviorClose']
            if b not in ('OK', 'INFORMATIONAL') or c not in ('OK', 'INFORMATIONAL'):
                bad['%s / close %s' % (b, c)].append(case)
        for kind, names in sorted(bad.items()):
            names.sort(key=key)
            shown = ' '.join(names[:40]) + (' ... (%d more)' % (len(names) - 40) if len(names) > 40 else '')
            print('  %s (%d): %s' % (kind, len(names), shown))
for line in missing:
    print(line)
EOF
for p in "${PROBLEMS[@]:-}"; do [ -n "$p" ] && echo "PROBLEM: $p"; done
log "reports: $WORK/reports, logs: $WORK/logs"
[ "${#PROBLEMS[@]}" = 0 ]

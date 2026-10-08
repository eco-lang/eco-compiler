# Shared helpers for test/conformance/autobahn.sh and h2spec.sh (sourced, not run).
#
# LOCAL ONLY: the conformance scripts download tools to /tmp and run for minutes; they are never
# part of CI (plans/eco-system-websockets.md W18, Appendix F).

CONF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$CONF_DIR/../.." && pwd)
BUILD=${ECO_BUILD_DIR:-$REPO/build}
EXAMPLES=$REPO/examples/system

log() { printf '[%s] %s\n' "$(basename "$0")" "$*" >&2; }
die() { log "error: $*"; exit 1; }

# fetch URL SHA256 FILE: download once, check the checksum.
fetch() {
    local url=$1 sum=$2 out=$3
    if [ ! -f "$out" ]; then
        log "downloading $url"
        mkdir -p "$(dirname "$out")"
        curl -fsSL --retry 3 -o "$out.part" "$url" || die "download failed: $url"
        mv "$out.part" "$out"
    fi
    echo "$sum  $out" | sha256sum -c --quiet - || die "checksum mismatch: $out (delete it to retry)"
}

# build_program MODULE NAME WORKDIR BACKENDS: compile examples/system/src/MODULE.elm with the
# Stage-1 compiler (compiler/bin/index.js) for each backend in BACKENDS ("native", "js" or both):
#   native: MODULE.elm -> WORKDIR/NAME.mlir -> eco-boot-native -> WORKDIR/NAME
#   js:     MODULE.elm -> WORKDIR/NAME.js plus a launcher WORKDIR/NAME.run.js
build_program() {
    local module=$1 name=$2 work=$3 backends=$4
    local guida=$BUILD/compiler/build-xhr/bin/guida.js
    local native=$BUILD/runtime/src/codegen/eco-boot-native
    [ -f "$guida" ] || die "missing $guida (cmake --build build --target guida)"
    mkdir -p "$work"
    case " $backends " in
    *native*)
        [ -x "$native" ] || die "missing $native (cmake --build build --target eco-boot-native)"
        log "compiling $module (native)"
        (cd "$EXAMPLES" && GUIDA_JS_PATH=$guida node "$REPO/compiler/bin/index.js" make "src/$module.elm" \
            --local-package "eco/system=$REPO/system-kernel-cpp" --output="$work/$name.mlir") \
            >"$work/$name.native-build.log" 2>&1 || { cat "$work/$name.native-build.log" >&2; die "compile failed: $module"; }
        "$native" "$work/$name.mlir" -o "$work/$name" >>"$work/$name.native-build.log" 2>&1 \
            || { tail -40 "$work/$name.native-build.log" >&2; die "eco-boot-native failed: $module"; }
        ;;
    esac
    case " $backends " in
    *js*)
        log "compiling $module (js)"
        (cd "$EXAMPLES" && GUIDA_JS_PATH=$guida node "$REPO/compiler/bin/index.js" make "src/$module.elm" \
            --local-package "eco/system=$REPO/system-kernel-cpp" --output="$work/$name.js") \
            >"$work/$name.js-build.log" 2>&1 || { cat "$work/$name.js-build.log" >&2; die "compile failed: $module (js)"; }
        printf "require('./%s.js').Elm.%s.init();\n" "$name" "$module" >"$work/$name.run.js"
        ;;
    esac
}

# program_cmd BACKEND WORKDIR NAME: the command line that runs a built program.
program_cmd() {
    case $1 in
    native) echo "$2/$3" ;;
    js) echo "node $2/$3.run.js" ;;
    *) die "unknown backend $1" ;;
    esac
}

# wait_port PORT [SECONDS]: wait until something accepts TCP connections on 127.0.0.1:PORT.
wait_port() {
    local port=$1 limit=${2:-30} i=0
    while ! (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; do
        i=$((i + 1))
        [ "$i" -le $((limit * 10)) ] || return 1
        sleep 0.1
    done
}

# port_free PORT: true when nothing listens on 127.0.0.1:PORT.
port_free() { ! (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

# stop_pid PID: terminate a background process and wait for it.
stop_pid() {
    local pid=$1
    [ -n "$pid" ] || return 0
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 50); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
    kill -9 "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
}

# write_test_tls DIR: the test certificate (localhost, 127.0.0.1), its key and CA, from
# test/eco-system/src/TlsFixtures.elm, as DIR/{cert,key,ca}.pem.
write_test_tls() {
    local dir=$1 fixtures=$REPO/test/eco-system/src/TlsFixtures.elm
    mkdir -p "$dir"
    pem_of() {
        awk -v name="$1" '
            $0 == name " =" { want = 1; next }
            want && /"""/ { if (inside) exit; inside = 1; sub(/.*"""/, ""); }
            want && inside { print }
        ' "$fixtures"
    }
    pem_of serverCertPem >"$dir/cert.pem"
    pem_of serverKeyPem >"$dir/key.pem"
    pem_of caPem >"$dir/ca.pem"
    grep -q 'BEGIN CERTIFICATE' "$dir/cert.pem" && grep -q 'PRIVATE KEY' "$dir/key.pem" \
        || die "could not extract the test certificate from $fixtures"
}

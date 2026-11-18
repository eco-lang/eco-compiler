#!/usr/bin/env bash
# Shows, changes and checks the versions eco builds against (deps/versions.env): Modular MAX, the
# llvm-project commit, uv and Python. See plans/llvm-24-upgrade.md, section 1.
#
#   scripts/deps.sh show               every pin, and whether this machine's LLVM matches it
#   scripts/deps.sh get KEY            one value (e.g. LLVM_COMMIT), for scripts
#   scripts/deps.sh max VERSION        move to MAX VERSION: re-lock deps/max/, and (LLVM_FOLLOWS=max)
#                                      move LLVM_COMMIT to that release's pin; says whether LLVM moved
#   scripts/deps.sh llvm REF           pin LLVM by hand (a commit or an llvmorg- tag; sets
#                                      LLVM_FOLLOWS=independent)
#   scripts/deps.sh follow-max         LLVM_FOLLOWS=max again, LLVM_COMMIT = MAX_VERSION's pin
#   scripts/deps.sh uv VERSION         pin uv
#   scripts/deps.sh python VERSION     pin the Python MAX is installed for (major.minor)
#   scripts/deps.sh win-clang VERSION  pin the clang-cl Windows CI compiles with (an LLVM release,
#                                      e.g. 23.1.5): records its x86_64-pc-windows-msvc archive's sha256
#   scripts/deps.sh lock               rewrite deps/max/pyproject.toml from the pins and re-lock
#   scripts/deps.sh check [--offline]  fail on any inconsistency (CI runs this); --offline skips the
#                                      look-up of MAX's LLVM pin
#   scripts/deps.sh max-pin VERSION    print the llvm-project commit MAX VERSION pins
#   scripts/deps.sh latest-max         print the newest MAX on PyPI and its LLVM pin
#   scripts/deps.sh artifact PLATFORM  print the registry reference of the prebuilt LLVM for
#                                      PLATFORM (debian, alpine, macos, windows): the commit plus a
#                                      hash of the platform's build recipe, so a recipe change gets
#                                      a new artifact. ECO_LLVM_REGISTRY overrides the registry.
#
# Runs on Linux, macOS (bash 3.2) and Git Bash on Windows.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
versions="$root/deps/versions.env"
maxdir="$root/deps/max"
registry="${ECO_LLVM_REGISTRY:-ghcr.io/eco-lang}"

die() { echo "deps: $*" >&2; exit 1; }

get() {
    local v
    v=$(sed -n "s/^$1=//p" "$versions" | tr -d '\r')
    [ -n "$v" ] || die "$1 is not set in deps/versions.env"
    printf '%s\n' "$v"
}

set_var() { # KEY VALUE: replace the KEY= line in place
    local tmp="$versions.tmp.$$"
    grep -q "^$1=" "$versions" || die "$1 is not in deps/versions.env"
    awk -v k="$1" -v v="$2" 'index($0, k "=") == 1 { print k "=" v; next } { print }' \
        "$versions" > "$tmp"
    mv "$tmp" "$versions"
}

fetch() { # URL -> stdout
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 3 "$1"
    else
        die "curl is needed to read $1"
    fi
}

sha256() { # stdin -> hex
    if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1
    else shasum -a 256 | cut -d' ' -f1
    fi
}

is_commit() { printf '%s' "$1" | grep -Eq '^[0-9a-f]{40}$'; }

max_pin() { # VERSION -> the llvm-project commit modular/modular pins at max/vVERSION
    local url="https://raw.githubusercontent.com/modular/modular/refs/tags/max/v$1/bazel/public-patches/llvm_source.bzl"
    local body c
    body=$(fetch "$url") || die "cannot read MAX $1's LLVM pin ($url): no such release, or the pin file moved"
    c=$(printf '%s\n' "$body" | sed -n 's/^LLVM_COMMIT = "\([0-9a-f]\{40\}\)"$/\1/p')
    is_commit "$c" || die "no LLVM_COMMIT = \"<40 hex>\" line in $url (the pin file's format changed)"
    printf '%s\n' "$c"
}

resolve_llvm_ref() { # commit or llvmorg- tag -> commit
    if is_commit "$1"; then printf '%s\n' "$1"; return; fi
    case "$1" in
        llvmorg-*) ;;
        *) die "'$1' is neither a 40-hex commit nor an llvmorg- tag" ;;
    esac
    local c
    c=$(git ls-remote https://github.com/llvm/llvm-project.git "refs/tags/$1^{}" | cut -f1)
    [ -n "$c" ] || c=$(git ls-remote https://github.com/llvm/llvm-project.git "refs/tags/$1" | cut -f1)
    is_commit "$c" || die "no such llvm-project tag: $1"
    printf '%s\n' "$c"
}

# Writes deps/max/pyproject.toml's pinned lines from deps/versions.env.
write_pyproject() {
    local py uvv mv tmp="$maxdir/pyproject.toml.tmp.$$"
    py=$(get PYTHON_VERSION); uvv=$(get UV_VERSION); mv=$(get MAX_VERSION)
    awk -v py="$py" -v uvv="$uvv" -v mv="$mv" '
        /^requires-python = / { print "requires-python = \"==" py ".*\""; next }
        /^    "max==/          { print "    \"max==" mv "\","; next }
        /^required-version = / { print "required-version = \">=" uvv "\""; next }
        { print }' "$maxdir/pyproject.toml" > "$tmp"
    mv "$tmp" "$maxdir/pyproject.toml"
    printf '%s\n' "$py" > "$maxdir/.python-version"
}

lock() {
    write_pyproject
    command -v uv >/dev/null 2>&1 || die "uv is needed to re-lock deps/max (uv $(get UV_VERSION))"
    (cd "$maxdir" && uv lock -q)
    echo "deps: deps/max/uv.lock re-locked for max==$(get MAX_VERSION) on Python $(get PYTHON_VERSION)"
}

recipe_file() {
    case "$1" in
        debian) echo "docker/llvm-debian.Dockerfile" ;;
        alpine) echo "docker/llvm-alpine.Dockerfile" ;;
        macos) echo "experiments/mac-llvm-build/build.sh" ;;
        windows) echo "experiments/win-llvm-build/build.ps1" ;;
        *) die "unknown platform '$1' (debian, alpine, macos, windows)" ;;
    esac
}

artifact() {
    local f h
    f=$(recipe_file "$1")
    # CRs dropped so a CRLF checkout hashes like an LF one.
    h=$(tr -d '\r' < "$root/$f" | sha256 | cut -c1-12)
    printf '%s/eco-llvm-%s:%s-%s\n' "$registry" "$1" "$(get LLVM_COMMIT)" "$h"
}

installed_llvm() { # prints the commit of the LLVM this machine would build against, if found
    local p
    for p in "${ECO_LLVM_PREFIX:-}" /opt/llvm-mlir "${ECO_MAC_DEPS_DIR:-}" "${LLVM_DIR:-}"; do
        if [ -n "$p" ] && [ -f "$p/ECO_LLVM_COMMIT" ]; then
            printf '%s (%s)\n' "$(tr -d '\r\n' < "$p/ECO_LLVM_COMMIT")" "$p"
            return
        fi
    done
    echo "none found"
}

show() {
    echo "MAX_VERSION     $(get MAX_VERSION)"
    echo "LLVM_FOLLOWS    $(get LLVM_FOLLOWS)"
    echo "LLVM_COMMIT     $(get LLVM_COMMIT) ($(get LLVM_DESCRIBE))"
    echo "UV_VERSION      $(get UV_VERSION)"
    echo "PYTHON_VERSION  $(get PYTHON_VERSION)"
    echo "WIN_CLANG       $(get WIN_CLANG_VERSION) (archive sha256 $(get WIN_CLANG_SHA256 | cut -c1-12)...)"
    echo "this machine's LLVM: $(installed_llvm)"
    if command -v uv >/dev/null 2>&1; then echo "this machine's uv:   $(uv --version)"; fi
}

check() {
    local offline="${1:-}" bad=0 c f follows want
    c=$(get LLVM_COMMIT)
    is_commit "$c" || { echo "deps: LLVM_COMMIT is not 40 lowercase hex digits: $c" >&2; bad=1; }
    follows=$(get LLVM_FOLLOWS)
    case "$follows" in max|independent) ;; *) echo "deps: LLVM_FOLLOWS must be max or independent" >&2; bad=1 ;; esac
    get WIN_CLANG_VERSION | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' \
        || { echo "deps: WIN_CLANG_VERSION is not an LLVM release number (N.N.N)" >&2; bad=1; }
    get WIN_CLANG_SHA256 | grep -qE '^[0-9a-f]{64}$' \
        || { echo "deps: WIN_CLANG_SHA256 is not 64 lowercase hex digits; run scripts/deps.sh win-clang" >&2; bad=1; }

    # deps/max/ in step with the pins.
    grep -q "^    \"max==$(get MAX_VERSION)\",\$" "$maxdir/pyproject.toml" \
        || { echo "deps: deps/max/pyproject.toml does not pin max==$(get MAX_VERSION); run scripts/deps.sh lock" >&2; bad=1; }
    grep -q "^requires-python = \"==$(get PYTHON_VERSION)\.\*\"\$" "$maxdir/pyproject.toml" \
        || { echo "deps: deps/max/pyproject.toml's requires-python is not $(get PYTHON_VERSION); run scripts/deps.sh lock" >&2; bad=1; }
    awk '/^name = "max"$/ { getline; print; exit }' "$maxdir/uv.lock" | grep -q "^version = \"$(get MAX_VERSION)\"\$" \
        || { echo "deps: deps/max/uv.lock does not lock max $(get MAX_VERSION); run scripts/deps.sh lock" >&2; bad=1; }

    # LLVM follows MAX.
    if [ "$follows" = max ] && [ "$offline" != --offline ]; then
        want=$(max_pin "$(get MAX_VERSION)")
        [ "$want" = "$c" ] || { echo "deps: LLVM_FOLLOWS=max, but MAX $(get MAX_VERSION) pins $want and LLVM_COMMIT is $c; run scripts/deps.sh follow-max" >&2; bad=1; }
    fi

    # No version written anywhere else. Historical records (plans, design docs, benchmark logs, the
    # pin log) and the vendored LLVM libc, which has its own pin, are exempt.
    local files hits
    if git -C "$root" rev-parse >/dev/null 2>&1; then
        files=$(git -C "$root" ls-files)
    else
        files=$(cd "$root" && find . -type f -not -path './build*' -not -path './.git/*' \
                    -not -path '*/node_modules/*' -not -path '*/elm-stuff/*' | sed 's|^\./||')
    fi
    hits=$(printf '%s\n' "$files" \
        | grep -v -E '^(deps/|plans/|design_docs/|benchmarks/|docs/llvm-pins\.md$|runtime/third_party/llvm-libc/|scripts/deps\.sh$)' \
        | (cd "$root" && xargs grep -I -l -E "$c|21\.1\.8|llvmorg-[0-9]|max==[0-9]|modular==[0-9]" 2>/dev/null) || true)
    if [ -n "$hits" ]; then
        echo "deps: these files write a version that belongs in deps/versions.env:" >&2
        printf '  %s\n' $hits >&2
        bad=1
    fi

    [ "$bad" = 0 ] || exit 1
    echo "deps: OK (MAX $(get MAX_VERSION), LLVM $c, follows $follows)"
}

cmd="${1:-show}"
shift || true
case "$cmd" in
    show) show ;;
    get) [ $# = 1 ] || die "usage: deps.sh get KEY"; get "$1" ;;
    max)
        [ $# = 1 ] || die "usage: deps.sh max VERSION"
        old_max=$(get MAX_VERSION); old_llvm=$(get LLVM_COMMIT)
        if [ "$(get LLVM_FOLLOWS)" = max ]; then new_llvm=$(max_pin "$1"); else new_llvm="$old_llvm"; fi
        set_var MAX_VERSION "$1"
        lock
        if [ "$new_llvm" = "$old_llvm" ]; then
            echo "deps: MAX $old_max -> $1; LLVM unchanged ($old_llvm): no LLVM rebuild, no port"
        else
            set_var LLVM_COMMIT "$new_llvm"
            set_var LLVM_DESCRIBE "unknown"
            echo "deps: MAX $old_max -> $1; LLVM moves $old_llvm -> $new_llvm"
            echo "deps: run the llvm-build workflow (or local-dev/build-images.sh --local), port, then set"
            echo "      LLVM_DESCRIBE to the new llvm-config --version (scripts/deps.sh show prints it)"
        fi
        ;;
    llvm)
        [ $# = 1 ] || die "usage: deps.sh llvm COMMIT|llvmorg-TAG"
        c=$(resolve_llvm_ref "$1")
        set_var LLVM_FOLLOWS independent
        set_var LLVM_COMMIT "$c"
        set_var LLVM_DESCRIBE "unknown"
        echo "deps: LLVM pinned by hand to $c (LLVM_FOLLOWS=independent); set LLVM_DESCRIBE once built"
        ;;
    follow-max)
        c=$(max_pin "$(get MAX_VERSION)")
        set_var LLVM_FOLLOWS max
        if [ "$c" != "$(get LLVM_COMMIT)" ]; then
            set_var LLVM_COMMIT "$c"; set_var LLVM_DESCRIBE "unknown"
        fi
        echo "deps: LLVM follows MAX $(get MAX_VERSION): $c"
        ;;
    uv) [ $# = 1 ] || die "usage: deps.sh uv VERSION"; set_var UV_VERSION "$1"; lock ;;
    python) [ $# = 1 ] || die "usage: deps.sh python MAJOR.MINOR"; set_var PYTHON_VERSION "$1"; lock ;;
    win-clang)
        [ $# = 1 ] || die "usage: deps.sh win-clang VERSION (an LLVM release, e.g. 23.1.5)"
        asset="clang+llvm-$1-x86_64-pc-windows-msvc.tar.zst"
        # GitHub records each release asset's sha256 as its `digest`.
        sum=$(fetch "https://api.github.com/repos/llvm/llvm-project/releases/tags/llvmorg-$1" \
              | python3 -c 'import json,sys
a = [x for x in json.load(sys.stdin)["assets"] if x["name"] == sys.argv[1]]
d = a[0].get("digest") or "" if a else ""
print(d[len("sha256:"):] if d.startswith("sha256:") else "")' "$asset")
        [ -n "$sum" ] || die "LLVM $1 has no $asset with a sha256 digest"
        set_var WIN_CLANG_VERSION "$1"
        set_var WIN_CLANG_SHA256 "$sum"
        echo "deps: Windows CI clang-cl pinned to LLVM $1 ($asset, sha256 $sum)"
        ;;
    lock) lock ;;
    check) check "${1:-}" ;;
    max-pin) [ $# = 1 ] || die "usage: deps.sh max-pin VERSION"; max_pin "$1" ;;
    latest-max)
        v=$(fetch https://pypi.org/pypi/max/json | python3 -c 'import json,sys; print(json.load(sys.stdin)["info"]["version"])')
        printf '%s %s\n' "$v" "$(max_pin "$v")"
        ;;
    artifact) [ $# = 1 ] || die "usage: deps.sh artifact debian|alpine|macos|windows"; artifact "$1" ;;
    -h|--help|help) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//' ;;
    *) die "unknown command '$cmd' (scripts/deps.sh help)" ;;
esac

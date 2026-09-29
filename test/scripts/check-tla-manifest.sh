#!/bin/sh
# check-tla-manifest.sh -- GC_MODEL_001: the TLA+ model canary.
#
#   usage: check-tla-manifest.sh <repo-root> [--update]
#
# The TLA+ models under test/tla/ (and the weak-memory drivers under
# test/genmc/) each describe some C++ code. When that code changes, the model
# may no longer describe it, and nothing else would notice: the models keep
# passing, about a program that no longer exists. This canary pins the code
# each model covers and fails the build when it changes
# (plans/threaded-gc-tla-verification.md section 7).
#
# test/tla/manifest.txt holds one pin per line:
#
#     <kind>  <sha256 or ->  <path or ->  <id or ->  <models, comma-separated>
#
#   file    the whole file, byte for byte
#   region  the text between "// TLA-REGION(<id>) begin" and
#           "// TLA-REGION(<id>) end" in <path>; // comments stripped,
#           whitespace collapsed, blank lines dropped
#   census  every line of <path> that matches the concurrency regex (after
#           stripping // comments), whitespace collapsed, sorted
#   grep    footprint row <id>: the matches of its re-derivation grep in
#           test/tla/footprint-greps.txt, normalised as for census
#   nocode  <id> is a model with no code to pin (the primer's toy)
#
# Census and grep pins also store the matched text in test/tla/census/, so a
# failure prints the lines that were added and removed, not just a hash.
#
# Checks (all must pass):
#   1. hash      every pin matches the current code;
#   2. markers   every TLA-REGION marker in the tree is pinned, is a single
#                begin/end pair, and every pinned region exists;
#   3. models    every model in test/tla/models.txt (and every weak-memory
#                driver file in test/genmc/drivers.txt: W1..W5, w_pool_done,
#                w_running_chain) has at least one pin, and
#                every pin names only known models;
#   4. footprint every row id in footprint-greps.txt appears in some model's
#                MAPPING.md, as a variable or a written abstraction;
#   5. census    every file under runtime/src/allocator/ that has a
#                concurrency line has a census pin (a new atomic or lock in
#                an unpinned file would otherwise arrive unguarded).
#
# --update fills in "-" hashes (new pins) and replaces changed hashes, and
# rewrites test/tla/census/. It REFUSES a changed hash until the AUDIT.md of
# every model the pin names contains an entry quoting the new hash's first 12
# hex digits: the verdict is written down before the manifest accepts the
# code. Running it is the last step of a re-audit, never a way to make a red
# build green.
#
# ECO_TLA_CANARY=warn turns a failure into a warning (for a branch in the
# middle of a phase). Phase gates, CI and merges run strict.
#
# The manifest is ASCII only: CMake reads it with file(STRINGS), which splits
# lines at non-ASCII bytes (see check-kernel-license-manifest.sh).

ROOT="$1"
MODE="$2"

if [ -z "$ROOT" ] || [ ! -d "$ROOT" ]; then
    echo "check-tla-manifest: usage: $0 <repo-root> [--update]" >&2
    exit 2
fi

TLA="$ROOT/test/tla"
MANIFEST="$TLA/manifest.txt"
GREPS="$TLA/footprint-greps.txt"
MODELS="$TLA/models.txt"
CENSUS_DIR="$TLA/census"
DRIVERS="$ROOT/test/genmc/drivers.txt"
# Where TLA-REGION markers may live, and the directory the census must cover.
MARKER_DIRS="runtime/src elm-kernel-cpp/src"
CENSUS_ROOT="runtime/src/allocator"
# The concurrency regex (parent plan 7.1), in a form awk takes without escapes.
CONC_RE='std::atomic|atomic_ref|memory_order|compare_exchange|fetch_(add|sub|or|and)|[.]exchange[(]|atomic_thread_fence|mutex|lock_guard|unique_lock|condition_variable|SpinMutex|pthread_atfork|std::thread'

for f in "$MANIFEST" "$GREPS" "$MODELS"; do
    if [ ! -f "$f" ]; then
        echo "check-tla-manifest: cannot read $f" >&2
        exit 2
    fi
done

sha256_of_stdin() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 | cut -d' ' -f1
    else
        echo "check-tla-manifest: no sha256sum or shasum on PATH" >&2
        exit 2
    fi
}

TMP="${TMPDIR:-/tmp}/tla-canary-$$"
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT

# --- text extraction ---------------------------------------------------------

# Strip // comments, collapse whitespace, drop blank lines.
normalise() {
    awk '{ sub(/\/\/.*$/, ""); gsub(/[ \t\r]+/, " "); sub(/^ /, ""); sub(/ $/, "");
           if ($0 != "") print }'
}

# region_text <path> <id>: the normalised text strictly between the markers.
region_text() {
    awk -v id="$2" '
        index($0, "TLA-REGION(" id ") end")   { inside = 0 }
        inside                                { print }
        index($0, "TLA-REGION(" id ") begin") { inside = 1 }
    ' "$ROOT/$1" | normalise
}

# census_text <path>: the concurrency lines, normalised and sorted.
census_text() {
    awk -v re="$CONC_RE" '{
            sub(/\/\/.*$/, "")
            if ($0 !~ re) next
            gsub(/[ \t\r]+/, " "); sub(/^ /, ""); sub(/ $/, "")
            if ($0 != "") print
        }' "$ROOT/$1" | LC_ALL=C sort
}

# grep_text <id>: the matches of footprint row <id>, "<path>: <line>", sorted.
grep_text() {
    row=$(awk -F '\t' -v id="$1" '$1 == id { print; exit }' "$GREPS")
    if [ -z "$row" ]; then
        echo "check-tla-manifest: footprint row $1 is not in $GREPS" >&2
        return 1
    fi
    globs=$(printf '%s\n' "$row" | cut -f2)
    re=$(printf '%s\n' "$row" | cut -f3)
    (
        cd "$ROOT" || exit 2
        files=""
        for g in $globs; do
            for p in $g; do
                [ -f "$p" ] && files="$files $p"
            done
        done
        [ -n "$files" ] || exit 0
        # One awk over every file: strip // comments, match, normalise, prefix the path.
        # shellcheck disable=SC2086
        awk -v re="$re" '{
                sub(/\/\/.*$/, "")
                if ($0 !~ re) next
                gsub(/[ \t\r]+/, " "); sub(/^ /, ""); sub(/ $/, "")
                if ($0 != "") print FILENAME ": " $0
            }' $files
    ) | LC_ALL=C sort
}

# pin_text <kind> <path> <id>: the text a pin hashes (not for kind file).
pin_text() {
    case "$1" in
        region) region_text "$2" "$3" ;;
        census) census_text "$2" ;;
        grep)   grep_text "$3" ;;
    esac
}

pin_hash() {
    case "$1" in
        file) sha256_of_stdin < "$ROOT/$2" ;;
        *)    pin_text "$1" "$2" "$3" | sha256_of_stdin ;;
    esac
}

census_file() {
    case "$1" in
        census) echo "$CENSUS_DIR/$(printf '%s' "$2" | sed 's|/|__|g').txt" ;;
        grep)   echo "$CENSUS_DIR/grep__$3.txt" ;;
    esac
}

# --- the manifest, the models, the markers -----------------------------------

# Pins, one per line: kind hash path id models
awk '!/^[ \t]*#/ && NF > 0 { print $1, $2, $3, $4, $5 }' "$MANIFEST" > "$TMP/pins"

bad=$(awk '
    NF != 5 { print "  line with " NF " fields: " $0; next }
    $1 !~ /^(file|region|census|grep|nocode)$/ { print "  unknown kind: " $0 }
' "$TMP/pins")
if [ -n "$bad" ]; then
    echo "check-tla-manifest: malformed lines in $MANIFEST:" >&2
    echo "$bad" >&2
    exit 2
fi

# Known models: the registry's, plus one per weak-memory driver file in test/genmc
# (drivers.txt's second column): w<n>_*.cpp is W<n>, w_<name>.cpp is w_<name>.
awk '!/^[ \t]*#/ && NF > 0 { print $1 }' "$MODELS" | sed 's/#.*//' > "$TMP/models.raw"
if [ -f "$DRIVERS" ]; then
    awk '!/^[ \t]*#/ && NF > 1 { print $2 }' "$DRIVERS" \
        | sed -n -e 's/^[wW]\([0-9][0-9]*\).*/W\1/p' -e 's/^\(w_[A-Za-z0-9_]*\)[.]cpp$/\1/p' \
        >> "$TMP/models.raw"
fi
LC_ALL=C sort -u "$TMP/models.raw" | awk 'NF' > "$TMP/models"

# audit_file <model>: the AUDIT.md an update of a pin naming <model> checks.
audit_file() {
    case "$1" in
        W[0-9]*|w_*) echo "$ROOT/test/genmc/AUDIT.md"; return ;;
    esac
    d=$(awk -v m="$1" '!/^[ \t]*#/ && $1 == m { print $2; exit }' "$MODELS")
    if [ -n "$d" ]; then echo "$TLA/$d/AUDIT.md"; fi
}

# Every marker in the tree: path id begin|end
(
    cd "$ROOT" || exit 2
    for d in $MARKER_DIRS; do
        [ -d "$d" ] || continue
        find "$d" -type f \( -name '*.cpp' -o -name '*.hpp' -o -name '*.h' -o -name '*.cc' \) \
            | LC_ALL=C sort | while read -r p; do
                awk -v p="$p" '
                    match($0, /TLA-REGION\([^)]*\) (begin|end)/) {
                        s = substr($0, RSTART, RLENGTH)
                        id = s; sub(/^TLA-REGION\(/, "", id); sub(/\).*$/, "", id)
                        what = s; sub(/^.* /, "", what)
                        print p, id, what
                    }' "$p"
            done
    done
) > "$TMP/markers"

# --- --update ----------------------------------------------------------------
if [ "$MODE" = "--update" ]; then
    : > "$TMP/refused"
    : > "$TMP/newhashes"
    while read -r kind want path id models; do
        if [ "$kind" = "nocode" ]; then
            echo "$kind $want $path $id $models" >> "$TMP/newhashes"
            continue
        fi
        if [ "$kind" != "grep" ] && [ ! -f "$ROOT/$path" ]; then
            echo "check-tla-manifest: $kind pin on a missing file: $path" >&2
            exit 1
        fi
        got=$(pin_hash "$kind" "$path" "$id")
        if [ "$want" != "-" ] && [ "$want" != "$got" ]; then
            prefix=$(printf '%s' "$got" | cut -c1-12)
            for m in $(printf '%s' "$models" | tr ',' ' '); do
                a=$(audit_file "$m")
                if [ -z "$a" ] || [ ! -f "$a" ] || ! grep -q "$prefix" "$a"; then
                    echo "  $kind $path $id: model $m has no AUDIT.md entry quoting $prefix (${a:-no AUDIT.md})" \
                        >> "$TMP/refused"
                fi
            done
        fi
        echo "$kind $got $path $id $models" >> "$TMP/newhashes"
    done < "$TMP/pins"
    if [ -s "$TMP/refused" ]; then
        echo "check-tla-manifest: --update REFUSED. These pins changed, and a model they name" >&2
        echo "has no re-audit verdict for the new code yet:" >&2
        cat "$TMP/refused" >&2
        echo "" >&2
        echo "Re-audit each named model (test/tla/README.md, 'The canary'), write its AUDIT.md" >&2
        echo "entry quoting the new hash prefix, then run --update again." >&2
        exit 1
    fi
    # Rewrite the manifest in place: the same lines and comments, new hashes.
    awk '
        NR == FNR { h[FNR] = $2; next }
        /^[ \t]*#/ || NF == 0 { print; next }
        { n++; printf "%-7s %s  %s  %s  %s\n", $1, h[n], $3, $4, $5 }
    ' "$TMP/newhashes" "$MANIFEST" > "$TMP/manifest.new"
    mv "$TMP/manifest.new" "$MANIFEST"
    mkdir -p "$CENSUS_DIR"
    rm -f "$CENSUS_DIR"/*.txt
    while read -r kind want path id models; do
        case "$kind" in
            census|grep) pin_text "$kind" "$path" "$id" > "$(census_file "$kind" "$path" "$id")" ;;
        esac
    done < "$TMP/pins"
    echo "check-tla-manifest: $(wc -l < "$TMP/pins" | tr -d ' ') pins written to $MANIFEST"
    # Fall through to the check, so a coverage hole still fails the update.
fi

# --- check -------------------------------------------------------------------
awk '!/^[ \t]*#/ && NF > 0 { print $1, $2, $3, $4, $5 }' "$MANIFEST" > "$TMP/pins"
: > "$TMP/report"
: > "$TMP/models-named"

while read -r kind want path id models; do
    printf '%s\n' "$models" | tr ',' '\n' >> "$TMP/models-named"
    [ "$kind" = "nocode" ] && continue
    if [ "$kind" != "grep" ] && [ ! -f "$ROOT/$path" ]; then
        printf '  %-7s %s  %s  (the file no longer exists)   models: %s\n' \
            "$kind" "$path" "$id" "$models" >> "$TMP/report"
        continue
    fi
    got=$(pin_hash "$kind" "$path" "$id")
    [ "$want" = "$got" ] && continue
    if [ "$want" = "-" ]; then
        printf '  %-7s %s  %s  (new pin, no hash yet)   models: %s\n' \
            "$kind" "$path" "$id" "$models" >> "$TMP/report"
        continue
    fi
    printf '  %-7s %s  %s   models: %s\n' "$kind" "$path" "$id" "$(printf '%s' "$models" | tr ',' ' ')" \
        >> "$TMP/report"
    case "$kind" in
        census|grep)
            cf=$(census_file "$kind" "$path" "$id")
            pin_text "$kind" "$path" "$id" > "$TMP/now.txt"
            if [ -f "$cf" ]; then
                diff "$cf" "$TMP/now.txt" | sed -n 's/^< /      - /p; s/^> /      + /p' >> "$TMP/report"
            fi
            ;;
    esac
    printf '      new hash prefix: %s\n' "$(printf '%s' "$got" | cut -c1-12)" >> "$TMP/report"
done < "$TMP/pins"

: > "$TMP/coverage"

# 2. markers: single begin/end pairs, all pinned; every pinned region exists.
awk '{ n[$1 " " $2 " " $3]++ }
     END { for (k in n) if (n[k] != 1) print "  marker " k " appears " n[k] " times" }' \
    "$TMP/markers" >> "$TMP/coverage"
awk '$3 == "begin" { print $1, $2 }' "$TMP/markers" | LC_ALL=C sort -u > "$TMP/marker-begins"
awk '$3 == "end" { print $1, $2 }' "$TMP/markers" | LC_ALL=C sort -u > "$TMP/marker-ends"
LC_ALL=C comm -3 "$TMP/marker-begins" "$TMP/marker-ends" \
    | sed 's/^[ \t]*/  unpaired marker (begin without end, or end without begin): /' >> "$TMP/coverage"
awk '$1 == "region" { print $3, $4 }' "$TMP/pins" | LC_ALL=C sort -u > "$TMP/pinned-regions"
LC_ALL=C comm -23 "$TMP/marker-begins" "$TMP/pinned-regions" \
    | sed 's/^/  unpinned TLA-REGION marker: /' >> "$TMP/coverage"
LC_ALL=C comm -13 "$TMP/marker-begins" "$TMP/pinned-regions" \
    | sed 's/^/  pinned region with no marker in the tree: /' >> "$TMP/coverage"
awk '{ print $2 }' "$TMP/marker-begins" | LC_ALL=C sort | uniq -d \
    | sed 's/^/  region id used in more than one file: /' >> "$TMP/coverage"

# 3. models: every known model is pinned; every named model is known.
LC_ALL=C sort -u "$TMP/models-named" | awk 'NF' > "$TMP/models-named.u"
LC_ALL=C comm -23 "$TMP/models" "$TMP/models-named.u" \
    | sed 's/^/  model with no pin (add its A9 lines, or a nocode line): /' >> "$TMP/coverage"
LC_ALL=C comm -13 "$TMP/models" "$TMP/models-named.u" \
    | sed 's/^/  pin names an unknown model: /' >> "$TMP/coverage"

# 4. footprint: every audit-table row id appears in some MAPPING.md, outside the generated
#    canary-pins block (so a pin listing alone does not count as coverage). Rows named
#    F.* are canary greps, not footprint rows, and are exempt.
awk -F '\t' '!/^[ \t]*#/ && NF >= 3 && $1 !~ /^F[.]/ { print $1 }' "$GREPS" | while read -r rid; do
    if ! cat "$TLA"/*/MAPPING.md 2>/dev/null \
        | awk '/<!-- canary-pins begin -->/ { skip = 1 } !skip { print } /<!-- canary-pins end -->/ { skip = 0 }' \
        | awk -v id="$rid" '
            { s = $0
              while ((i = index(s, id)) > 0) {
                  before = (i > 1) ? substr(s, i - 1, 1) : " "
                  after = substr(s, i + length(id), 1)
                  if (before !~ /[A-Za-z0-9_.]/ && after !~ /[A-Za-z0-9_]/) { found = 1; exit }
                  s = substr(s, i + length(id))
              } }
            END { exit !found }'; then
        echo "  footprint row $rid appears in no model's MAPPING.md" >> "$TMP/coverage"
    fi
done
awk -F '\t' '!/^[ \t]*#/ && NF >= 3 && $3 != "-" { print $1 }' "$GREPS" | LC_ALL=C sort > "$TMP/grep-rows"
awk '$1 == "grep" { print $4 }' "$TMP/pins" | LC_ALL=C sort -u > "$TMP/pinned-greps"
LC_ALL=C comm -23 "$TMP/grep-rows" "$TMP/pinned-greps" \
    | sed 's/^/  footprint row with no grep pin in the manifest: /' >> "$TMP/coverage"

# 5. census: every allocator file with a concurrency line has a census pin.
awk '$1 == "census" { print $3 }' "$TMP/pins" | LC_ALL=C sort -u > "$TMP/pinned-census"
(
    cd "$ROOT" || exit 2
    find "$CENSUS_ROOT" -type f \( -name '*.cpp' -o -name '*.hpp' -o -name '*.h' \) | LC_ALL=C sort \
        | while read -r p; do
            if awk -v re="$CONC_RE" '{ sub(/\/\/.*$/, "") } $0 ~ re { f = 1; exit } END { exit !f }' "$p"; then
                echo "$p"
            fi
        done
) > "$TMP/census-needed"
LC_ALL=C comm -23 "$TMP/census-needed" "$TMP/pinned-census" \
    | sed 's/^/  allocator file with concurrency lines and no census pin: /' >> "$TMP/coverage"

if [ ! -s "$TMP/report" ] && [ ! -s "$TMP/coverage" ]; then
    exit 0
fi

{
    if [ -s "$TMP/report" ]; then
        echo "TLA+ model canary: code covered by a concurrency model has changed."
        echo ""
        cat "$TMP/report"
        echo ""
        echo "DO NOT just repair the hash. The models named above may no longer describe the code."
        echo "Before running --update:"
        echo "  1. Read the change. Does it add, remove or reorder an atomic step, a lock, a shared"
        echo "     location or a memory order? Does it touch a footprint row (MAPPING.md)?"
        echo "  2. Check each affected action and variable in the named models' MAPPING.md."
        echo "  3. If a model no longer matches: update the spec and MAPPING.md, then run"
        echo "       cmake --build build --target tla-check      (mutants included)"
        echo "     and, if the change is in a traced path, tla-trace."
        echo "  4. Add an AUDIT.md entry to EACH named model: the date, what changed, the verdict"
        echo "     (no model change needed / model updated, and why), and the new hash prefix."
        echo "  5. Only then: test/scripts/check-tla-manifest.sh . --update"
        echo "If the change looks like a defect, add it to plans/threaded-gc-concurrency-register.md."
    fi
    if [ -s "$TMP/coverage" ]; then
        [ -s "$TMP/report" ] && echo ""
        echo "TLA+ model canary: coverage holes (plans/threaded-gc-tla-verification.md 7.2):"
        echo ""
        cat "$TMP/coverage"
        echo ""
        echo "Pin the new code in test/tla/manifest.txt (hash '-'), name the models that cover it,"
        echo "and run: test/scripts/check-tla-manifest.sh . --update"
    fi
} >&2

if [ "$ECO_TLA_CANARY" = "warn" ]; then
    echo "check-tla-manifest: ECO_TLA_CANARY=warn: reporting only." >&2
    exit 0
fi
exit 1

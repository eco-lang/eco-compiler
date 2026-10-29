#!/bin/sh
# check-kernel-license-manifest.sh — LSS_022 license-rot guard.
#
#   usage: check-kernel-license-manifest.sh <repo-root> [--update]
#
# A KernelSetFacts `TypeFaithful` row is a CONTRACT ON C++ THAT ELM CANNOT
# SEE. The row says "this kernel's set flow is exactly its Elm type's
# variable-sharing graph", and the compiler then skips the LSS_004 poison at
# every call to it. A later edit to the audited C++ body can invalidate that
# silently — and the failure mode is a wrong direct-call stamp, i.e. a
# miscompile, not a test failure. Elm tests cannot read files, so the guard
# lives here, in the build tree.
#
# The audit data lives in two CSV files beside KernelSetFacts.elm, not in the
# Elm tables, which keep only what the compiler reads:
#
#   kernel-license-files.csv   kernel,file,sha256,audited
#       One line per (licensed or intrinsic-annotated kernel x audited C++
#       file), with the file's sha256 and the date of the kernel's latest
#       audit when the hash was taken.
#   kernel-license-audit.csv   kernel,date,plan,note
#       One line per audit or re-audit of a row. `date` is YYYY-MM-DD (empty
#       only for a first audit whose date was never recorded); `plan` names
#       the plans/*.md file behind it, if any.
#
# A license kernel is named `<Prefix>.<Home>.<name>` (`Elm.File.size`), an
# intrinsic annotation `<Prefix>.Kernel.<Home>.<name>`, so an intrinsic pin is
# never confused with a license pin on the same file. The `kernel` and `date`
# columns never contain a comma; `note` may, and is quoted.
#
# Checks:
#
#   1. HASH: every pinned file still has its sha256.
#   2. COVERAGE: the kernels pinned in the files CSV are exactly the
#      `TypeFaithful` rows of KernelSetFacts.elm plus the rows of
#      KernelIntrinsics.elm, every pinned path is repo-relative, and no row
#      pins the other kernel tree's C++ (an `Elm` row nothing under
#      eco-kernel-cpp/ or system-kernel-cpp/, an `Eco` row nothing under
#      elm-kernel-cpp/).
#   3. AUDIT: every row of either table has an audit line, every audit line
#      names a row, a license's first audit carries the class:, entry:,
#      type:, B1:, B2: and B3: markers and a `Positional` row's carries
#      entry:, a license is `Inert` exactly when its audit says
#      `class: vacuous`, and each pin's `audited` date is its kernel's latest
#      audit date.
#
# `--update` re-hashes the pinned files and sets each pin's `audited` date. It
# is the LAST step of a re-audit, never a way to make a red build green: it
# refuses to change a hash unless the kernel has an audit line dated after the
# pin's current `audited` date. New pins are added to the files CSV by hand,
# with the sha256 and audited columns left empty for `--update` to fill.
#
# Scope note (deliberate): the CSV pins the kernel's OWN C++ — the entry
# point's file and the helper files the audit had to read. It does NOT pin
# globally-sanctioned runtime machinery (the four `eco_apply_closure*`
# application entries, allocator/list-builder headers). Those are shared by
# every kernel and are not a per-license risk; pinning them would rot every
# row on unrelated allocator churn while adding no per-kernel signal.

set -e

ROOT="$1"
MODE="$2"

if [ -z "$ROOT" ] || [ ! -d "$ROOT" ]; then
    echo "check-kernel-license-manifest: usage: $0 <repo-root> [--update]" >&2
    exit 2
fi

DIR="$ROOT/compiler/src/Compiler/MonoSolver"
FACTS="$DIR/KernelSetFacts.elm"
INTRINSICS="$ROOT/compiler/src/Compiler/Type/KernelIntrinsics.elm"
FILES_CSV="$DIR/kernel-license-files.csv"
AUDIT_CSV="$DIR/kernel-license-audit.csv"

for f in "$FACTS" "$INTRINSICS" "$FILES_CSV" "$AUDIT_CSV"; do
    if [ ! -f "$f" ]; then
        echo "check-kernel-license-manifest: cannot read $f" >&2
        exit 2
    fi
done

# --- sha256 front-end (Linux coreutils / BSD / macOS) ------------------------
sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | cut -d' ' -f1
    else
        echo "check-kernel-license-manifest: no sha256sum or shasum on PATH" >&2
        exit 2
    fi
}

TMP="${TMPDIR:-/tmp}/kernel-license-$$"
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT

# --- the rows of the two Elm tables: kernel <TAB> kind <TAB> scope -----------
#
# The table's shape is fixed by elm-format, so a small state machine is
# enough and avoids a Python dependency in the build graph:
#
#     , ( ( "Elm", "JsArray", "map" )
#       , TypeFaithful
#             { scope = Transports
#             }
#       )
#
# A `( ( "Prefix", "Home", "name" )` line opens a row. A `TransportsAs` scope
# may start on the line after `scope =`, below a comment.
cat > "$TMP/rows.awk" <<'AWK'
function flush() { if (kernel != "") print kernel "\t" kind "\t" scope }
{
    if ($0 ~ /\( \( "[^"]+", "[^"]+", "[^"]+" \)/) {
        flush()
        s = $0
        sub(/^[^(]*\( \( "/, "", s)
        p = s; sub(/".*/, "", p)
        t = s; sub(/^[^"]*", "/, "", t)
        h = t; sub(/".*/, "", h)
        n = t; sub(/^[^"]*", "/, "", n); sub(/".*/, "", n)
        kernel = p "." h "." n
        kind = "-"; scope = "-"; inscope = 0
        next
    }
    if (kernel == "") next
    if ($0 ~ /^[ \t]*, TypeFaithful[ \t]*$/) kind = "TypeFaithful"
    if ($0 ~ /^[ \t]*, Positional[ \t]*$/) kind = "Positional"
    if ($0 ~ /scope =/) inscope = 1
    if (inscope && $0 !~ /^[ \t]*--/) {
        if (match($0, /TransportsAs/)) { scope = "TransportsAs"; inscope = 0 }
        else if (match($0, /Transports/)) { scope = "Transports"; inscope = 0 }
        else if (match($0, /Inert/)) { scope = "Inert"; inscope = 0 }
    }
}
END { flush() }
AWK
awk -f "$TMP/rows.awk" "$FACTS" > "$TMP/rows"

# The intrinsic annotation table is keyed the same way; its rows are labelled
# `<Prefix>.Kernel.<Home>.<name>`.
awk '
    /\( \( "[^"]+", "[^"]+", "[^"]+" \)/ {
        s = $0
        sub(/^[^(]*\( \( "/, "", s)
        p = s; sub(/".*/, "", p)
        t = s; sub(/^[^"]*", "/, "", t)
        h = t; sub(/".*/, "", h)
        n = t; sub(/^[^"]*", "/, "", n); sub(/".*/, "", n)
        print p ".Kernel." h "." n "\tIntrinsic\t-"
    }
' "$INTRINSICS" >> "$TMP/rows"

sort -u "$TMP/rows" > "$TMP/rows.sorted"
awk -F'\t' '$2 == "TypeFaithful" || $2 == "Intrinsic" { print $1 }' "$TMP/rows.sorted" | sort -u > "$TMP/pinnable"

# --- the CSVs -----------------------------------------------------------------
# kernel <TAB> latest audit date (empty when no audit line has a date)
awk -F, 'NR > 1 { k = $1; if (!(k in latest)) latest[k] = ""; if ($2 > latest[k]) latest[k] = $2 }
         END { for (k in latest) print k "\t" latest[k] }' "$AUDIT_CSV" | sort > "$TMP/latest"

# --- --update: re-hash the pins ----------------------------------------------
if [ "$MODE" = "--update" ]; then
    head -n 1 "$FILES_CSV" > "$TMP/files.new"
    REFUSED=0
    tail -n +2 "$FILES_CSV" | while IFS=, read -r kernel file want audited; do
        [ -n "$kernel" ] || continue
        if [ ! -f "$ROOT/$file" ]; then
            echo "check-kernel-license-manifest: $kernel pins a file that does not exist: $file" >&2
            echo "FAIL" >> "$TMP/refused"
            continue
        fi
        got=$(sha256_of "$ROOT/$file")
        latest=$(awk -F'\t' -v k="$kernel" '$1 == k { print $2 }' "$TMP/latest")
        if [ "$got" != "$want" ] && [ -n "$audited" ] && ! [ "$latest" \> "$audited" ]; then
            echo "check-kernel-license-manifest: refusing to re-hash $file for $kernel:" >&2
            echo "  its latest audit ($latest) is not after the pin's ($audited). Add a" >&2
            echo "  re-audit line to kernel-license-audit.csv first." >&2
            echo "FAIL" >> "$TMP/refused"
            echo "$kernel,$file,$want,$audited"
            continue
        fi
        echo "$kernel,$file,$got,$latest"
    done | sort -t, -k1,1 -k2,2 >> "$TMP/files.new"
    if [ -f "$TMP/refused" ]; then
        exit 1
    fi
    mv "$TMP/files.new" "$FILES_CSV"
    echo "check-kernel-license-manifest: wrote $(($(wc -l < "$FILES_CSV") - 1)) pins to $FILES_CSV"
    exit 0
fi

# --- check mode ----------------------------------------------------------------
STATUS=0
fail() { echo "check-kernel-license-manifest: $*" >&2; STATUS=1; }

# 2. COVERAGE
tail -n +2 "$FILES_CSV" | cut -d, -f1 | sort -u > "$TMP/pinned"
if ! diff -u "$TMP/pinned" "$TMP/pinnable" > "$TMP/coverage.diff" 2>&1; then
    fail "PIN COVERAGE MISMATCH"
    echo "  The kernels pinned in kernel-license-files.csv differ from the" >&2
    echo "  TypeFaithful rows of KernelSetFacts.elm and the rows of" >&2
    echo "  KernelIntrinsics.elm. '-' lines are pinned but no longer rows; '+'" >&2
    echo "  lines are rows with no pin — an UNGUARDED license or annotation." >&2
    sed 's/^/  /' "$TMP/coverage.diff" >&2
    echo "  Fix: re-audit per plans/kernel-parametricity-license.md §2, add the" >&2
    echo "  pins and the audit line, then run $0 $ROOT --update" >&2
fi

tail -n +2 "$FILES_CSV" | awk -F, '
    $2 ~ /^\// || $2 !~ /\// { print "  " $1 ": " $2 " is not a repo-relative path" }
    $1 ~ /^Elm\./ && ($2 ~ /^eco-kernel-cpp\// || $2 ~ /^system-kernel-cpp\//) { print "  " $1 " pins the eco kernel C++ " $2 }
    $1 ~ /^Eco\./ && $2 ~ /^elm-kernel-cpp\// { print "  " $1 " pins the elm kernel C++ " $2 }
' > "$TMP/paths"
if [ -s "$TMP/paths" ]; then
    fail "bad pinned paths:"
    cat "$TMP/paths" >&2
fi

# 3. AUDIT
cut -f1 "$TMP/rows.sorted" | sort -u > "$TMP/rowkernels"
tail -n +2 "$AUDIT_CSV" | cut -d, -f1 | sort -u > "$TMP/audited"
if ! diff -u "$TMP/audited" "$TMP/rowkernels" > "$TMP/audit.diff" 2>&1; then
    fail "AUDIT COVERAGE MISMATCH"
    echo "  '-' lines are audited kernels with no row; '+' lines are rows with no" >&2
    echo "  line in kernel-license-audit.csv." >&2
    sed 's/^/  /' "$TMP/audit.diff" >&2
fi

awk -F, 'NR > 1 && $2 != "" && $2 !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/ { print "  line " NR ": bad date " $2 }' \
    "$AUDIT_CSV" > "$TMP/dates"
awk -F'\t' '$2 == "" { print "  " $1 " has no dated audit" }' "$TMP/latest" >> "$TMP/dates"
if [ -s "$TMP/dates" ]; then
    fail "bad audit dates:"
    cat "$TMP/dates" >&2
fi

# The first audit line of each kernel carries the markers.
awk -F'\t' 'NR == FNR { kind[$1] = $2; scope[$1] = $3; next }
    FNR == 1 { next }
    {
        split($0, f, ",")
        k = f[1]
        if (k in seen) next
        seen[k] = 1
        if (kind[k] == "TypeFaithful") {
            n = split("class: entry: type: B1: B2: B3:", req, " ")
            for (i = 1; i <= n; i++) if (index($0, req[i]) == 0) print "  " k ": first audit lacks " req[i]
            vac = index($0, "class: vacuous") > 0
            if (vac != (scope[k] == "Inert")) print "  " k ": scope " scope[k] " but the audit class " (vac ? "is" : "is not") " vacuous"
        } else if (kind[k] == "Positional") {
            if (index($0, "entry:") == 0) print "  " k ": first audit lacks entry:"
        }
    }' "$TMP/rows.sorted" "$AUDIT_CSV" > "$TMP/markers"
if [ -s "$TMP/markers" ]; then
    fail "malformed audits:"
    cat "$TMP/markers" >&2
fi

# 1. HASH, and each pin's audited date.
tail -n +2 "$FILES_CSV" | while IFS=, read -r kernel file want audited; do
    [ -n "$kernel" ] || continue
    if [ ! -f "$ROOT/$file" ]; then
        echo "check-kernel-license-manifest: kernel $kernel is licensed against" >&2
        echo "  $file, which no longer exists." >&2
        echo "  Re-audit per plans/kernel-parametricity-license.md §2 and update" >&2
        echo "  the pins." >&2
        echo "FAIL" >> "$TMP/hashfail"
        continue
    fi
    got=$(sha256_of "$ROOT/$file")
    if [ "$got" != "$want" ]; then
        echo "check-kernel-license-manifest: kernel $kernel is licensed against a C++" >&2
        echo "  body that has changed — $file" >&2
        echo "    pinned:  $want" >&2
        echo "    current: $got" >&2
        echo "  Re-audit per plans/kernel-parametricity-license.md §2 (application-only" >&2
        echo "  through the sanctioned entry points, no retention, no fabrication or" >&2
        echo "  laundering, honest type), add a dated re-audit line for the kernel to" >&2
        echo "  kernel-license-audit.csv, then run $0 <repo-root> --update." >&2
        echo "  If the kernel can no longer be licensed, demote the row to Positional" >&2
        echo "  or delete it — a wrong license is a miscompile, a missing one costs" >&2
        echo "  only precision." >&2
        echo "FAIL" >> "$TMP/hashfail"
        continue
    fi
    latest=$(awk -F'\t' -v k="$kernel" '$1 == k { print $2 }' "$TMP/latest")
    if [ "$audited" != "$latest" ]; then
        echo "check-kernel-license-manifest: $kernel pins $file as audited $audited," >&2
        echo "  but its latest audit line is dated $latest. Run $0 <repo-root> --update." >&2
        echo "FAIL" >> "$TMP/hashfail"
    fi
done

if [ -f "$TMP/hashfail" ]; then
    STATUS=1
fi

exit $STATUS

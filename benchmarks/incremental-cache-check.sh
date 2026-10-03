#!/bin/bash
# incremental-cache-check.sh -- gate G6 (plans/cache-serialization-optimization.md §1, §5.12e).
#
# Proves that an incremental build over warm per-module caches (.eci/.ecot/d.dat)
# emits the same MLIR as a cold build of the same source tree, with and without
# --builddir. Per PROJECT x MODE (root | builddir):
#   A   cold build (eco-stuff wiped)
#   A0  warm no-op rebuild                  cmp A0 A   (catches the S12b path mismatch)
#   [-n] N  one-shot (--no-cache) cold build cmp N A, eco-stuff untouched, then warm == A (S4)
#   per PHASE: mutate leaf + hub, then
#     B   incremental rebuild over the warm caches
#     C   cold build of the same tree (eco-stuff moved aside, then restored, so paths are identical)
#     cmp B C   (touch phase also: cmp B A)
#   finally: cmp root/A builddir/A
# Phases: touch (mtime only -> RSame path), body (append dead defs), iface (expose the
# hub probe -> RNew cascade), and for synth also sem (change hub/leaf values) and
# shape (add a constructor to the hub's exposed type).
#
# usage: incremental-cache-check.sh [-e ECO] [-o OUT] [-m "root builddir"] [-n] [-k] [synth|stress|compiler]...
# exit:  0 all equal | 1 an MLIR/cache mismatch | 2 a build failed | 3 usage/setup error
set -u
ulimit -c 0

REPO=/work
ECO=$REPO/build/compiler/build-kernel/bin/eco
OUT=/tmp/incr-cache-check-$(date +%Y%m%d-%H%M%S)
MODES="root builddir"
ONESHOT=0
KEEP=0
while getopts "e:o:m:nk" opt; do
  case $opt in
    e) ECO=$OPTARG ;; o) OUT=$OPTARG ;; m) MODES=$OPTARG ;;
    n) ONESHOT=1 ;; k) KEEP=1 ;; *) echo "usage: $0 [-e ECO] [-o OUT] [-m MODES] [-n] [-k] [synth|stress|compiler]..." >&2; exit 3 ;;
  esac
done
shift $((OPTIND - 1))
PROJECTS=${*:-synth}
[ -x "$ECO" ] || { echo "no compiler at $ECO" >&2; exit 3; }
if [ "$ONESHOT" = 1 ] && ! "$ECO" make --help 2>&1 | grep -q -- '--no-cache'; then
  echo "-n given but $ECO has no --no-cache flag (S4 not built)" >&2; exit 3
fi
mkdir -p "$OUT" || exit 3
SUMMARY=$OUT/summary.tsv
printf 'project\tmode\tstep\tresult\tseconds\n' > "$SUMMARY"
WORST=0
fail() { [ "$1" -gt "$WORST" ] && WORST=$1; }
# Avoid the slow registry POST (memory: heap-profile-revived-gc-baseline).
for r in "$HOME"/.eco/*/packages/registry.dat; do [ -f "$r" ] && touch "$r"; done

# ---------------------------------------------------------------- projects
gen_synth() {   # $1 = tree
  local t=$1 k
  mkdir -p "$t/src" && cp "$REPO/test/elm/elm.json" "$t/elm.json" || return 1
  cat > "$t/src/Hub.elm" <<'EOF'
module Hub exposing (Shape(..), area, hubValue, scale)


type Shape
    = Circle Int
    | Square Int -- SHAPES


area : Shape -> Int
area shape =
    case shape of
        Circle r ->
            3 * r * r

        Square s ->
            s * s -- AREA


hubValue : Int
hubValue =
    1 -- HUBVAL


scale : Int -> Int
scale x =
    x * hubValue
EOF
  for k in 1 2 3 4 5 6; do
    cat > "$t/src/Mid$k.elm" <<EOF
module Mid$k exposing (mid$k)

import Hub exposing (Shape(..))


mid$k : Int -> Int
mid$k n =
    Hub.scale (Hub.area (Circle (n + $k))) + Hub.area (Square $k)
EOF
  done
  cat > "$t/src/Leaf.elm" <<'EOF'
module Leaf exposing (leafValue)

import Hub
import Mid3


leafValue : Int
leafValue =
    Mid3.mid3 7 + Hub.hubValue + 1 -- LEAFVAL
EOF
  cat > "$t/src/Main.elm" <<'EOF'
module Main exposing (main)

import Html exposing (text)
import Leaf
import Mid1
import Mid2
import Mid3
import Mid4
import Mid5
import Mid6


main =
    let
        total =
            Leaf.leafValue + Mid1.mid1 1 + Mid2.mid2 2 + Mid3.mid3 3 + Mid4.mid4 4 + Mid5.mid5 5 + Mid6.mid6 6

        _ =
            Debug.log "IncrCheck" total
    in
    text "ok"
EOF
}

setup_project() {   # $1 = project, $2 = tree; sets ENTRY HUB LEAF FLAGS PHASES
  local p=$1 t=$2
  rm -rf "$t" && mkdir -p "$t" || return 1
  case $p in
    synth)
      gen_synth "$t" || return 1
      ENTRY=src/Main.elm; HUB=src/Hub.elm; LEAF=src/Leaf.elm; FLAGS=()
      PHASES="touch body iface sem shape" ;;
    stress)
      cp -r "$REPO/test/stress-elm/src" "$t/src" && cp "$REPO/test/stress-elm/elm.json" "$t/" || return 1
      ENTRY=src/JsonRoundtripNestedTree.elm; HUB=src/StressHarness.elm; LEAF=src/Xorshift32.elm
      FLAGS=(--local-package "eco/kernel=$REPO/eco-kernel-cpp")
      PHASES="touch body iface" ;;
    compiler)
      cp -r "$REPO/compiler/src" "$t/src" && cp "$REPO/compiler/cmake/bootstrap/build-kernel/elm.json" "$t/" || return 1
      ENTRY=src/Terminal/Main.elm; HUB=src/Compiler/Data/Name.elm; LEAF=src/Terminal/Bump.elm
      FLAGS=(--optimize --kernel-package eco/compiler --local-package "eco/kernel=$REPO/eco-kernel-cpp")
      PHASES="touch body iface" ;;
    *) echo "unknown project $p" >&2; return 1 ;;
  esac
}

# ---------------------------------------------------------------- mutations
append_probe() { printf '\n\n%s : Int\n%s =\n    %s\n' "$2" "$2" "$3" >> "$1"; }
expose_probe() {   # insert NAME as the first item of FILE's exposing list (no-op for exposing (..))
  local f=$1 n=$2 tmp
  tmp=$(mktemp) || return 1
  awk -v n="$n" '
    !done && /exposing/ { seen = 1 }
    !done && seen && index($0, "(") > 0 {
      i = index($0, "(")
      if (substr($0, i + 1) !~ /^[ ]*\.\.[ ]*\)/) { $0 = substr($0, 1, i) " " n "," substr($0, i + 1) }
      done = 1
    }
    { print }' "$f" > "$tmp" && mv "$tmp" "$f"
}
mutate() {   # $1 = phase (cwd = tree)
  sleep 1
  case $1 in
    touch) touch "$HUB" "$LEAF" ;;
    body)  append_probe "$HUB" incrCheckHubProbe_ 41 && append_probe "$LEAF" incrCheckLeafProbe_ 42 ;;
    iface) expose_probe "$HUB" incrCheckHubProbe_ && grep -q 'incrCheckHubProbe_,\|exposing (\.\.)' "$HUB" ;;
    sem)   sed -i 's/1 -- HUBVAL/2 -- HUBVAL/' "$HUB" && sed -i 's/+ 1 -- LEAFVAL/+ 2 -- LEAFVAL/' "$LEAF" ;;
    shape) sed -i 's/^    | Square Int -- SHAPES$/    | Square Int\n    | Tri Int -- SHAPES/' "$HUB" &&
           sed -i 's/^            s \* s -- AREA$/            s * s\n\n        Tri t ->\n            t * t -- AREA/' "$HUB" &&
           grep -q 'Tri t ->' "$HUB" ;;
  esac
}

# ---------------------------------------------------------------- builds
# build STEP [extra flags...]   (cwd = tree; uses PROJ MODE LOGD BD)
build() {
  local step=$1; shift
  local t0 t1 rc dt out=$LOGD/$step.mlir
  t0=$(date +%s.%N)
  "$ECO" make "${FLAGS[@]}" "${BD[@]}" "$@" --output="$out" "$ENTRY" > "$LOGD/$step.log" 2>&1
  rc=$?
  t1=$(date +%s.%N)
  dt=$(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.1f", b - a }')
  if [ $rc -ne 0 ] || [ ! -s "$out" ] || grep -q 'Corrupt File\|CORRUPT CACHE' "$LOGD/$step.log"; then
    printf '%s\t%s\t%s\tBUILD-FAIL(rc=%s)\t%s\n' "$PROJ" "$MODE" "$step" "$rc" "$dt" >> "$SUMMARY"
    echo "  $step: BUILD FAILED rc=$rc (log $LOGD/$step.log)"; tail -5 "$LOGD/$step.log" | sed 's/^/    /'
    fail 2; return 1
  fi
  printf '%s\t%s\t%s\tok\t%s\n' "$PROJ" "$MODE" "$step" "$dt" >> "$SUMMARY"
  echo "  $step: ok ($dt s)"
}
cold_aside() {   # cold build of the current tree without destroying the incremental state
  local step=$1; shift
  rm -rf eco-stuff.inc && { [ -d eco-stuff ] && mv eco-stuff eco-stuff.inc; }
  build "$step" "$@"; local rc=$?
  rm -rf eco-stuff && { [ -d eco-stuff.inc ] && mv eco-stuff.inc eco-stuff; }
  return $rc
}
same() {   # same A B label
  if cmp -s "$LOGD/$1.mlir" "$LOGD/$2.mlir"; then
    printf '%s\t%s\tcmp %s %s\tsame\t-\n' "$PROJ" "$MODE" "$1" "$2" >> "$SUMMARY"; echo "  cmp $1 $2: same"
  else
    printf '%s\t%s\tcmp %s %s\tDIFF\t-\n' "$PROJ" "$MODE" "$1" "$2" >> "$SUMMARY"; echo "  cmp $1 $2: DIFF"; fail 1
  fi
}

# ---------------------------------------------------------------- main loop
for PROJ in $PROJECTS; do
  for MODE in $MODES; do
    TREE=$OUT/work/$PROJ-$MODE; LOGD=$OUT/$PROJ-$MODE; mkdir -p "$LOGD"
    echo "== $PROJ / $MODE"
    setup_project "$PROJ" "$TREE" || { echo "setup failed" >&2; fail 3; continue; }
    case $MODE in root) BD=() ;; builddir) BD=(--builddir=g6check) ;; *) echo "bad mode $MODE" >&2; fail 3; continue ;; esac
    cd "$TREE" || { fail 3; continue; }
    rm -rf eco-stuff
    build A || continue
    build A0 && same A0 A
    if [ "$ONESHOT" = 1 ]; then
      find eco-stuff -type f ! -path '*/build/*' -printf '%P %s %T@\n' | sort > "$LOGD/stuff.before"
      cold_aside N --no-cache && same N A
      build N1 --no-cache && same N1 A        # one-shot over warm caches
      find eco-stuff -type f ! -path '*/build/*' -printf '%P %s %T@\n' | sort > "$LOGD/stuff.after"
      if cmp -s "$LOGD/stuff.before" "$LOGD/stuff.after"; then echo "  one-shot left eco-stuff untouched"
      else echo "  one-shot WROTE into eco-stuff (diff $LOGD/stuff.*)"; fail 1; fi
      build N2 && same N2 A                   # warm normal build after one-shot
    fi
    for ph in $PHASES; do
      mutate "$ph" || { echo "  mutate $ph failed" >&2; fail 3; break; }
      build "B-$ph" || continue
      cold_aside "C-$ph" || continue
      same "B-$ph" "C-$ph"
      [ "$ph" = touch ] && same "B-$ph" A
    done
    cd "$OUT" || exit 3
  done
  case " $MODES " in *" root "*) case " $MODES " in *" builddir "*)
    if cmp -s "$OUT/$PROJ-root/A.mlir" "$OUT/$PROJ-builddir/A.mlir"; then echo "== $PROJ: root/A == builddir/A"
    else echo "== $PROJ: root/A != builddir/A"; fail 1; fi ;; esac ;; esac
done

[ "$KEEP" = 1 ] || [ "$WORST" -ne 0 ] || rm -rf "$OUT/work"
echo "summary: $SUMMARY  (exit $WORST)"
column -t -s $'\t' "$SUMMARY" 2>/dev/null || cat "$SUMMARY"
exit $WORST

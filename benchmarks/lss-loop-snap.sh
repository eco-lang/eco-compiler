#!/bin/bash
# lss-loop-snap.sh — snapshot / restore / diff / verify the source trees the LSS compile-time
# optimization loop may change (benchmarks/lss-compile-opt-loop.md). This container has no working
# git, so snapshots ARE the version history of the loop: one per attempted step, one per kept win.
#
#   lss-loop-snap.sh snap    <name> [note...]   copy the trees into snapshots/lss-loop/<name>/
#   lss-loop-snap.sh restore <name>             make the live trees IDENTICAL to <name> (adds, overwrites, deletes)
#   lss-loop-snap.sh verify  <name>             exit 0 iff the live trees are identical to <name>
#   lss-loop-snap.sh diff    <a> <b>            unified patch turning <a> into <b> (stdout)
#   lss-loop-snap.sh list                       snapshots with their MANIFEST note
#
# Covers the source trees AND the build files a step may have to edit alongside them (CMake link
# lists, the kernel package manifest): reverting sources without the build file that names them
# would leave a build pointing at a file that no longer exists. A path added to the lists after a
# snapshot was taken is skipped for that snapshot rather than deleted from the live tree.
#
# Restore is content-aware: only files whose bytes differ are rewritten (fresh mtime, so ninja and
# the E2E mtime caches see them as changed); identical files keep their mtime; files present in
# the live tree but absent from the snapshot are deleted; empty directories left behind are removed.
# It ends with a full `diff -r` and FAILS LOUDLY if the tree is not byte-identical to the snapshot.

ROOT=/work
SNAPS=$ROOT/snapshots/lss-loop
DIRS="compiler/src compiler/src-xhr runtime/src elm-kernel-cpp/src eco-kernel-cpp/src compiler/tests test/eco-kernel/src"
# Individual files a step may change. Build files matter because a step that ADDS a source file
# also adds it to a link list, and reverting only the sources would leave the build referring to a
# file that is gone. Added 2026-09-19 for step 3 (the CellStore kernel), which touches all four.
FILES="compiler/CMakeLists.txt test/CMakeLists.txt eco-kernel-cpp/CMakeLists.txt eco-kernel-cpp/elm.json runtime/src/codegen/CMakeLists.txt design_docs/invariants.csv"

# A snapshot taken before a path joined the lists simply does not contain it. Such a path is
# SKIPPED on restore/verify/diff rather than treated as "the snapshot says this should not exist" —
# deleting live files because an old snapshot predates them would be the opposite of fool-proof.
have() { [ -e "$1" ]; }

# Paths the HARNESS rewrites, which must never count as a source change.
# test/eco-kernel/src/TestServerConfig.elm carries the in-process test server's
# port and is regenerated with a new port by every E2E run, so tracking it
# would make `verify` fail after every gate.
EXCLUDES="test/eco-kernel/src/TestServerConfig.elm"
DIFF_X=""
for e in $EXCLUDES; do DIFF_X="$DIFF_X --exclude=$(basename "$e")"; done

excluded() {
  for e in $EXCLUDES; do [ "$1" = "$e" ] && return 0; done
  return 1
}

die() { echo "lss-loop-snap: $*" >&2; exit 1; }

cmd=${1:-}; shift || true
case "$cmd" in
  snap)
    name=${1:-}; [ -n "$name" ] || die "snap needs a name"; shift
    dest=$SNAPS/$name
    [ -e "$dest" ] && die "snapshot already exists: $dest (snapshots are never overwritten)"
    mkdir -p "$dest"
    for d in $DIRS; do
      mkdir -p "$dest/$(dirname "$d")"
      cp -a "$ROOT/$d" "$dest/$d" || die "copy failed for $d"
    done
    for e in $EXCLUDES; do rm -f "$dest/$e"; done
    for f in $FILES; do
      mkdir -p "$dest/$(dirname "$f")"
      cp -a "$ROOT/$f" "$dest/$f" || die "copy failed for $f"
    done
    { echo "name: $name"; echo "date: $(date -u +%FT%TZ)"; echo "dirs: $DIRS"; echo "files: $FILES"; echo "note: $*"; } > "$dest/MANIFEST"
    echo "snapshot written: $dest"
    ;;
  restore)
    name=${1:-}; [ -n "$name" ] || die "restore needs a name"
    src=$SNAPS/$name; [ -d "$src" ] || die "no such snapshot: $src"
    for d in $DIRS; do
      have "$src/$d" || { echo "skipped  $d (not in snapshot $name)"; continue; }
      # 1. copy files that are missing or differ (fresh mtime on every rewritten file)
      ( cd "$src/$d" && find . -type f -print0 ) | while IFS= read -r -d '' f; do
        excluded "$d/${f#./}" && continue
        if ! cmp -s "$src/$d/$f" "$ROOT/$d/$f"; then
          mkdir -p "$(dirname "$ROOT/$d/$f")"
          cp --preserve=mode "$src/$d/$f" "$ROOT/$d/$f" || die "copy failed: $d/$f"
          echo "restored $d/$f"
        fi
      done
      # 2. delete files that exist in the live tree but not in the snapshot
      ( cd "$ROOT/$d" && find . -type f -print0 ) | while IFS= read -r -d '' f; do
        excluded "$d/${f#./}" && continue
        if [ ! -e "$src/$d/$f" ]; then rm -f "$ROOT/$d/$f" && echo "deleted  $d/$f"; fi
      done
      # 3. drop directories the step created
      ( cd "$ROOT/$d" && find . -depth -type d -empty -print0 ) | while IFS= read -r -d '' e; do
        [ "$e" = "." ] && continue
        [ -d "$src/$d/$e" ] || rmdir "$ROOT/$d/$e" 2>/dev/null && echo "rmdir    $d/$e"
      done
    done
    for f in $FILES; do
      have "$src/$f" || { echo "skipped  $f (not in snapshot $name)"; continue; }
      if ! cmp -s "$src/$f" "$ROOT/$f"; then
        cp --preserve=mode "$src/$f" "$ROOT/$f" || die "copy failed: $f"
        echo "restored $f"
      fi
    done
    for d in $DIRS; do
      have "$src/$d" || continue
      diff -r $DIFF_X "$src/$d" "$ROOT/$d" >/dev/null || die "RESTORE FAILED — $d still differs from $name (see: diff -r $src/$d $ROOT/$d)"
    done
    for f in $FILES; do
      have "$src/$f" || continue
      cmp -s "$src/$f" "$ROOT/$f" || die "RESTORE FAILED — $f still differs from $name"
    done
    echo "tree restored to snapshot $name (verified byte-identical)"
    echo "if the step added or removed .elm/.cpp files, re-run: cmake --preset build   (CMake globs sources at configure time)"
    ;;
  verify)
    name=${1:-}; [ -n "$name" ] || die "verify needs a name"
    src=$SNAPS/$name; [ -d "$src" ] || die "no such snapshot: $src"
    ok=1
    for d in $DIRS; do have "$src/$d" || continue; diff -rq $DIFF_X "$src/$d" "$ROOT/$d" || ok=0; done
    for f in $FILES; do have "$src/$f" || continue; cmp -s "$src/$f" "$ROOT/$f" || { echo "differs: $f"; ok=0; }; done
    [ $ok = 1 ] && echo "live tree == snapshot $name" || die "live tree DIFFERS from $name"
    ;;
  diff)
    a=${1:-}; b=${2:-}; [ -n "$a" ] && [ -n "$b" ] || die "diff needs two snapshot names"
    [ -d "$SNAPS/$a" ] && [ -d "$SNAPS/$b" ] || die "no such snapshot"
    for d in $DIRS; do ( cd "$SNAPS" && [ -e "$a/$d" -o -e "$b/$d" ] && diff -ruN $DIFF_X "$a/$d" "$b/$d" ); done
    for f in $FILES; do ( cd "$SNAPS" && [ -e "$a/$f" -o -e "$b/$f" ] && diff -uN "$a/$f" "$b/$f" ); done
    exit 0
    ;;
  list)
    for m in "$SNAPS"/*/MANIFEST; do [ -f "$m" ] && { sed -n 's/^name: //p' "$m" | tr '\n' ' '; sed -n 's/^date: //p' "$m" | tr '\n' ' '; sed -n 's/^note: //p' "$m"; }; done
    ;;
  *)
    sed -n '2,12p' "$0"; exit 1
    ;;
esac

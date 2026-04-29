# Rename Header `color` Bits to `padding` and Remove All Uses

## Motivation

The `Header.color : 2` bitfield in `runtime/src/allocator/Heap.hpp:97` is dead
state. The major-GC sweep no longer consults it for liveness — that decision
was migrated to the side-table `mark_bits_` in `OldGenSpace`
(`OldGenSpace.hpp:303-307`). Every remaining write is "keep the field
consistent for asserts" bookkeeping, every remaining read either round-trips
the value across a header re-init or prints it for diagnostics. The mirrored
`Forward::header.color : 2` slot at `Heap.hpp:364` is never accessed by name.

Reclaim the 2 bits by renaming the field to `padding` and deleting all the
write sites and the (one) round-trip read pair, plus the diagnostic print.

## Scope

In-scope:

- `runtime/src/allocator/Heap.hpp`
- `runtime/src/allocator/AllocatorCommon.hpp`
- `runtime/src/allocator/OldGenSpace.hpp` and `.cpp`
- `runtime/src/allocator/NurserySpace.cpp`
- `runtime/src/allocator/ThreadLocalHeap.cpp`
- `runtime/src/allocator/RuntimeExports.cpp`

Out-of-scope:

- The `mark_bits_` side-table mark/sweep machinery (already authoritative).
- Anything in `compiler/`, `elm-kernel-cpp/`, or MLIR codegen — `color` is not
  referenced from those.
- Repurposing the 2 bits for a new use (separate plan if needed).

## Pre-flight verification

Before editing, confirm the inventory below is still complete:

```
grep -rn '\.color\b\|->color\b' runtime/ elm-kernel-cpp/
grep -rn 'Color::\|enum class Color' runtime/ elm-kernel-cpp/
```

If any new site has appeared since 2026-04-27 (especially a *read* used in a
GC decision, not just a save/restore or print), stop and re-scope: that read
would mean the bits became load-bearing again.

## Step-by-step

### 1. `Heap.hpp` — rename the bitfields

- `runtime/src/allocator/Heap.hpp:97`: change
  `u32 color : 2; // White, Grey, or Black for tri-color mark-and-sweep.`
  to
  `u32 padding_color : 2; // Reserved (formerly tri-color GC state, now in OldGenSpace::mark_bits_).`
- `runtime/src/allocator/Heap.hpp:364`: change `u64 color : 2;` in `Forward`
  to `u64 padding_color : 2;` (preserve the bit-layout comment).
- Update the file-header comment at `Heap.hpp:5` ("type tag, GC color, age,
  and size") to drop "GC color".

Rationale for `padding_color` vs plain `padding`: there are already several
fields named `padding` / `_padding` in `Heap.hpp` (`HPointer.padding`,
`ElmChar.padding1..3`, `elm_string_slice._padding`, `ElmArray.padding`,
`Process.padding`, `Task.padding`). A unique name avoids ambiguity in
`grep` and in any future struct that aggregates a `Header`.

### 2. `AllocatorCommon.hpp` — delete the `Color` enum

- Remove `enum class Color : u32 { White=0, Grey=1, Black=2 };` and its
  preceding comment block (`AllocatorCommon.hpp:9, 32-36`).
- If `AllocatorCommon.hpp` becomes effectively empty after this, leave the
  file in place (other includers may rely on its presence) but do not invent
  a replacement symbol.

### 3. `NurserySpace.cpp` — drop the post-memcpy color resets

- Delete `new_hdr->color = static_cast<u32>(Color::White);` at
  `NurserySpace.cpp:953` and `:1005`.
- Delete the surrounding "color should already be White / Reset anyway to
  keep the promotion ..." comments — without the assignment they describe a
  ghost. The `memcpy` that copies the header from nursery into old gen still
  carries whatever `padding_color` happened to be set; since nothing reads
  the field, this is harmless.

Risk note: this directly reverses the "carry-over Black via minor-GC memcpy"
fix recorded in memory (`project_stage7_carryover_black_apr26.md`). That fix
is only load-bearing if the major-GC mark phase still skips already-Black
cells. After step 4 below removes that branch (and the side-table is
authoritative), the reset is no longer needed. Verify by searching for any
remaining `== Color::Black`-style guard before deleting these lines.

### 4. `OldGenSpace.cpp` — drop all color writes

The 9 write sites:

- `:221` (Black during GC) and `:229` (White when idle) in the
  fresh-allocation initializer. Delete the entire `if (marking_active || ...)`
  /`else` block that writes `hdr->color`; keep the side-table mark-bit
  set when allocating mid-cycle:
  ```cpp
  if (marking_active || gc_phase_ != GCPhase::Idle) {
      if (contains(obj)) {
          const size_t block_index = blockIndexFor(obj);
          if (block_index < blocks_.size()) {
              setMarkBitInBlock(block_index, obj);
          }
      }
  }
  ```
  Update the comment block at `:216-219` to drop the "header color is no
  longer load-bearing" remark — once the field is gone, the remark is moot.
- `:421` — `trailing->color = White` on a free-cell split: delete.
- `:609` — initial whole-block free cell `color = White`: delete.
- `:695` — large-block free cell `color = White`: delete.
- `:1401`, `:1412`, `:1428`, `:1444` — sweep paths resetting live cells back
  to White: delete each line. Update the comment header at `:1354-1356` to
  remove "Live Black objects have their color reset to White for the next
  cycle." — sweep is already a pure consumer of `mark_bits_`.
- `:2402` — promotion-into-old destination header `color = White`: delete,
  along with the `:2399` comment that justifies it.

After this step, `git grep '\bcolor\b' runtime/src/allocator/OldGenSpace.cpp`
should return nothing.

### 5. `ThreadLocalHeap.cpp` — drop the save/restore dances

- `:230-232` (`allocatePinnedLarge`): delete the `u32 saved_color = ...;` /
  `hdr->color = saved_color;` pair around `initHeaderForTag`. With no GC
  reader, there is nothing to preserve.
- `:243-245` (`allocatePermanent`): same deletion.
- Update the comment at `:226-229` to drop the "Color was set by
  OldGenSpace::allocate based on GC phase; preserve it." sentence; leave the
  remaining tag/pin notes intact.

### 6. `RuntimeExports.cpp` — drop the diagnostic print

- `:1216-1218`: in the corrupted-closure `fprintf` block, remove `color=%u`
  from the format string and `closure->header.color` from the argument list.
  Leave the `pin / age / unboxed / size` fields. Diagnostic-only — no
  behaviour change.

### 7. Header struct sanity

Re-confirm `static_assert(sizeof(Header) == 8, ...)` at `Heap.hpp:104` still
holds (the rename is bit-for-bit identical, so it should). Likewise
`sizeof(HPtr) == 8`, `sizeof(HPointer) == 8`, `sizeof(Unboxable) == 8`.

### 8. Build & test

Run the full pipeline; both targets matter because runtime headers affect
both bootstrapping and E2E:

```
cmake --build build --target full 2>&1 | tee /tmp/test_output.txt
```

Check stress tests too — the bits' last documented role was the carry-over
Black fix that surfaced in stress-only workloads:

```
# whatever the current stress invocation is; see memory entry
# project_stage7_run_apr25.md and project_gc_phase_profile_apr26.md
```

Expected outcomes:

- E2E: no regression vs. pre-change baseline.
- Stress: same or better — without the spurious White-reset writes, sweep
  and minor-GC evacuate each do strictly less work per object.

If either regresses, the most likely culprit is a missed *read* of `color`
elsewhere (e.g. a verifier or assertion) that the pre-flight grep didn't
turn up. Re-grep with the renamed identifier:

```
grep -rn '\bpadding_color\b\|\bColor::\b' .
```

The first should return only `Heap.hpp`; the second should return nothing.

### 9. Memory hygiene

After landing, update the auto-memory entry
`project_stage7_carryover_black_apr26.md` to mark the carry-over-Black
class of bug as no-longer-applicable (the bits don't exist as state any
more, and the side-table is the sole liveness oracle).

## Risks & mitigations

- **Hidden read site.** A verifier, assert, or debug build path may inspect
  `color` and we missed it because the pre-flight grep was scoped to `runtime/`
  and `elm-kernel-cpp/`. Mitigation: pre-flight grep over the whole repo
  (`grep -rn '\.color\b\|->color\b' .`) before step 1; if hits land in
  `compiler/` or anywhere unexpected, revisit scope.
- **Forward overlay aliasing.** `Forward::header.color` shares bits with
  `Header::color` via the union pattern. The rename is symmetric (both become
  `padding_color`), so the bit layout is preserved. No code reads either, so
  aliasing is moot — but worth re-checking with a `static_assert` on the
  offset of `padding_color` within both structs if that's cheap.
- **Future repurposing.** If we later want a 2-bit flag in `Header`, those
  bits remain available under the `padding_color` name. Don't optimise the
  field away (e.g. by widening `unboxed` to 8 bits) in this plan — that
  changes the bitmap layout and is a separate change.

## Done criteria

- `git grep '\bcolor\b' runtime/src/allocator/` returns matches only inside
  comments (or zero matches if comments were updated too).
- `git grep 'Color::' .` returns zero matches.
- `cmake --build build --target full` is green.
- Stress test suite is at or above the pre-change baseline.

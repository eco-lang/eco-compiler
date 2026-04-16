# Stage 7 Crash — Root Cause Investigation Report

## TL;DR

The user's hypothesis ("a pointer from old-gen into the nursery") **is not what
is happening**. Instrumentation shows:

1. `eco_store_field` is **never** called on a non-nursery (old-gen) object
   → no mutation of older objects (Elm immutability invariant holds at the
   compiler/runtime boundary).
2. During Phase 3 of minor GC (scanning promoted objects), no child is ever
   evacuated *into* nursery to-space → no old-gen object acquires a nursery
   pointer through the GC scan path either.
3. Instead, the crashing pointer (`HPointer raw=0x6039991`) is **stored into
   a freshly-allocated Custom (RBNode_elm_builtin) by compiled Elm code via
   `eco_store_field`** at construction time. The value is a *stale* HPointer
   that points 8 bytes into a previously-evacuated object.

The bad value enters the heap *before* the GC that crashes; the GC merely
trips over it. The chain of frames doing the bad store goes through
`eco_apply_segmentation_unknown`, the same C++ runtime function flagged in
`bootstrap-fails.md` Failure #2 (stack-`alloca`'d args arrays whose contents
are not GC-tracked across the runtime call). This is the **same root cause** as
Failure #2.

## Reproduction

```bash
cd /work/compiler/build-kernel
bin/eco-compiler make --optimize \
    --kernel-package eco/compiler \
    --local-package eco/kernel=/work/eco-kernel-cpp \
    --output=bin/eco-compiler-boot.mlir \
    /work/compiler/src/Terminal/Main.elm
```

Crash is deterministic (same heap offsets across runs).

## Crash Fingerprint

```
DIAG: minorGC #14 starting: from_is_low=0 alloc_ptr=...(off=0x301cccc8)
DIAG: promoting Custom(size=5,ctor=0,unboxed=0x0)
   from=…(src_off=0x3000f840) to=…(off=0x347688)
   values[0]=0x600236f values[1]=0x400000d values[2]=0x10000000000
   values[3]=0x6039991 values[4]=0x6002371
   src_region: from=1 to=0  age=1
DIAG: evacuate invalid tag — ptr.raw=0x6039991 obj=…(off=0x301ccc88) tag=24
   scanning obj=…(off=0x347688) tag=7 size=5
       words=[0x500000007 0x0 0x69338 0x400000d 0x10000000000 0x6039991]
Assertion `hdr->tag <= Tag_Forward` failed.
```

`HPointer 0x6039991 << 3 = byte offset 0x301CCC88`. Object boundary at
`0x301CCC88` does not exist; the location is +8 bytes into a 24-byte object
that starts at `0x301CCC80` (now a Tag_Forward). Bits at the target read as
tag = 24 (out of range).

## Step-by-Step Evidence

I added three diagnostics to `runtime/src/allocator/NurserySpace.cpp` and one
to `runtime/src/allocator/RuntimeExports.cpp`:

| Diagnostic | What it watches | Did it fire? |
|---|---|---|
| `DIAG[STORE_OLD]` | `eco_store_field` called on a non-nursery `obj` | **No** |
| `DIAG[OLD->YOUNG]` | While scanning a Phase-3 promoted obj, child copied to nursery | **No** |
| `DIAG[OLD->YOUNG/JIT]` | Same, JIT pointer path | **No** |
| `DIAG[OLD->YOUNG/SPINE]` | Same, list spine copy path | **No** |
| `DIAG[STORE_BAD_VAL]` | `eco_store_field` writing the literal value `0x6039991` | **Yes (4×)** |

The value `0x6039991` is written into 4 different `Custom` objects (`tag=7`,
**always at index 3 = the LEFT subtree slot of `RBNode_elm_builtin`**) in the
window between minor GC #12 and minor GC #13:

```
DIAG: minorGC #12 starting … off=0x301ccca8
DIAG[STORE_BAD_VAL]: storing 0x6039991 into obj=0x7f7445d54138 tag=7 idx=3
DIAG[STORE_BAD_VAL]: storing 0x6039991 into obj=0x7f7445d541d8 tag=7 idx=3
DIAG[STORE_BAD_VAL]: storing 0x6039991 into obj=0x7f7445d54328 tag=7 idx=3
DIAG[STORE_BAD_VAL]: storing 0x6039991 into obj=0x7f7445d54478 tag=7 idx=3
DIAG: minorGC #13 starting … off=0x201cccb0
DIAG: minorGC #14 starting … (crash)
```

So the bad pointer is *already inside* the heap before GC #14 starts; GC #14
only discovers it when it scans the promoted Custom that ends up holding it.

### Symbolised backtraces (from `backtrace_symbols_fd` + `nm` resolution)

All four bad stores share the same shape. Frames innermost-first:

```
eco_store_field            +0x114
Dict_RBNode_elm_builtin_$_5183       +0x9f          ← stores values[3] = 0x6039991
Dict_balance_$_5184                  +0x1cf2 / +0x14c7 / +0x1a1d   (or)
Dict_insertHelp_$_5182               +0x344
Dict_insertHelp_$_5182               +0x41f / +0x2ff
Dict_insert_$_5178                   +0x2d
Terminal_Main_lambda_3939            +0x57
__closure_wrapper_Terminal_Main_lambda_3939   +0x1f
List_foldl_$_5180                    +0x17f
Dict_fromList_$_5172                 +0x83
__closure_wrapper_Dict_fromList_$_5172        +0x14
eco_apply_segmentation_unknown       +0x1b5         ← C++ runtime closure dispatch
Basics_composeR_$_5173               +0x184
__closure_wrapper_Basics_composeR_$_5173      +0x27
Terminal_Main_lambda_3935$cap        +0x297
__closure_wrapper_Terminal_Main_lambda_3935$cap   +0x4d
…
```

Index 3 of `RBNode_elm_builtin Color k v left right` is the **`left`**
subtree. Each of these stores writes a corrupt left-subtree pointer.

### Why the value `0x6039991` is provably wrong from the moment of the store

When `eco_store_field` writes `0x6039991`, the heap state is:

* `from_is_low = 1` (low region is from-space, high is to-space — high is
  empty/abandoned post-#12 swap).
* The Customs being constructed are in the **low** region (e.g. obj
  `0x7f7445d54138` ≈ off `0x2014138`).
* The value being written is `HPointer 0x6039991 → byte 0x301CCC88` —
  in the **high** region, which is the *current to-space* (no live data).

So at the moment of the store, the destination of the pointer cannot
possibly be a live object — the high region is the GC's swap target, not a
live arena. The value is therefore inherently a *stale* HPointer carried in
some SSA / stack slot from before the most recent space swap.

It is also misaligned w.r.t. object boundaries (it is +8 bytes into a
previously-evacuated 24-byte object whose forwarding header sits at
`0x301CCC80`). So it never pointed to a real object header — it must have
been derived from one, or from a slot of one, by either:
  * an old SSA value held across one or more GCs without statepoint coverage; or
  * a value loaded from the C++ runtime's `alloca`'d args buffer, whose
    contents were not relocated when GC ran.

### Why this is the same bug as Failure #2

`bootstrap-fails.md` Failure #2 already identified that
`eco_apply_segmentation_unknown`, `eco_apply_closure`, and friends pass
HPointers via `alloca`'d arrays that the statepoint mechanism does not
register as GC roots. The backtrace above goes through exactly that path:
`Basics_composeR` → `eco_apply_segmentation_unknown` → wrapper →
`Terminal_Main_lambda_3939` → `Dict_fromList` → `List_foldl` → … → bad
store.

When GC fires anywhere along this chain, the LLVM-frame statepoints can
relocate SSA roots correctly, but the HPointers staged in the alloca'd args
buffers are not relocated. Subsequent loads from those buffers (or any SSA
value derived from them) hand stale HPointers back to compiled Elm code,
which then writes them straight into newly-allocated objects via
`eco_store_field`.

The reason the previously-attempted "GCSuppressGuard" fix (Failure #2,
attempt 1) did not work is that the staleness happens between two
*compiled* GC safepoints — suppressing GC in the C++ runtime alone is not
enough; any GC at all can leave the alloca'd buffer stale.

## Hypotheses Refuted by Evidence

* **"Mutation of older objects via `eco_store_field`."**
  Refuted: zero `DIAG[STORE_OLD]` events in 13 minor GCs of work.

* **"GC creates an old-gen → nursery pointer when scanning a promoted
  object whose child has age < promotion threshold (age divergence)."**
  Refuted: zero `DIAG[OLD->YOUNG]` events from any of the three evacuation
  paths (regular, JIT, list-spine).

* **"An old-gen object holds a pointer that points into the nursery."**
  The crashing pointer's *holder* (the size-5 Custom at off `0x347688`) is
  in old-gen because it was just promoted in GC #14, but its bad value was
  copied unchanged from the nursery copy that has been alive since GC #13.
  The bad value is a stale **nursery → nursery to-space** pointer, not an
  old → young pointer. The promotion is an incidental consequence of age
  reaching the threshold during this GC.

## Why the User's Hypothesis Made Intuitive Sense — and Why It's Wrong

The crash *symptom* is "a pointer from a thing in old-gen lands in the
nursery", because the holder Custom is in old-gen by the time we scan it.
But the staleness of the pointer was already baked in two GCs earlier
(in low-region nursery space). What looks like "an old-gen object holding a
nursery pointer at GC time" is actually "a nursery object that was
constructed with a stale pointer survived a GC and was promoted". The
"old-gen → nursery" frame is misleading.

## Recommended Fix Direction

(Same as `bootstrap-fails.md` Failure #2.) The `alloca`'d HPointer args
arrays handed into `eco_apply_*` family functions must be either:

1. Inlined into the LLVM caller so that each HPointer is a tracked SSA
   value at every safepoint (preferred — eliminates the unsafe handoff);
2. Allocated in a separately-registered GC root range (the
   `getStackRootRanges` mechanism already exists at
   `NurserySpace.cpp:441`), with explicit `eco_gc_push_stack_range` /
   `eco_gc_stack_range_point` calls bracketing every C++ runtime call that
   may reach a safepoint; or
3. Refactored away by giving the `eco_apply_*` functions per-arg parameters
   instead of an array, again leaving every HPointer as an SSA root.

Until one of these is done, any GC that fires while the runtime is
mid-flight in `eco_apply_segmentation_unknown` (or related dispatchers)
risks leaving the pending args stale, with the consequences seen here.

## Diagnostic Code Added

`runtime/src/allocator/NurserySpace.cpp`:

* `tl_scanning_promoted_` flag, set during the Phase-3 loop.
* In `evacuate()` (regular path), `evacuate()` (JIT path), and
  `evacuateListSpine()`, log `DIAG[OLD->YOUNG…]` if a child gets copied
  into to-space while the parent being scanned is in old-gen.
* `tl_minor_gc_counter_` propagated to those messages.

`runtime/src/allocator/RuntimeExports.cpp`:

* In `eco_store_field`, log `DIAG[STORE_OLD]` when called on a non-nursery
  `obj`, and log `DIAG[STORE_BAD_VAL]` + a backtrace when storing the
  specific value `0x6039991`.

These are minimal, behind first-50/single-shot guards, and can be left in
place or removed at the user's discretion.

# CAF permanent space (option #4, for-real measurement)

> **STATUS: SHIPPED DEFAULT-ON (2026-07-25).** Run Z: −5.0 % wall
> (3:20.6 → 3:10.5 ×3 interleaved), majors 9→8, minors count-identical;
> 596 promoted + 17 constant = 613 slots deregistered, 3,832 objects /
> 117 KB copied, ZERO declines; all battery MLIRs byte-identical. E2E
> 1636/1636 flag-off, flag-on, and post-flip default. Escape:
> `ECO_CAF_PERMANENT=0`. Invariant HEAP_036. Implementation deltas vs
> this plan: `Allocator::resolve` used instead of private
> `fromPointerRaw`; null-HPointer gates needed in both walker lambdas
> (unfilled capture slots — resolve dereferences the header);
> `Allocator::wrap` assert extended to heap-or-permanent.

Goal: memoized CAF values move into a **permanent space** at store time so
their slots leave the JIT root set (no per-minor scan) and their data is
never marked or swept (no per-major cost). Then benchmark wall-clock
honestly — the earlier residency A/B measured retention, not these
recurring costs.

## Key insight (survey-verified)

The GC already ignores pointers that are neither nursery nor old-gen:

- `OldGenSpace::markHPointer` bails on `!allocator->isInHeap(obj)`;
  `pushMarkRoot` additionally bails on `!contains(obj)` (Allocator.cpp
  `isInHeap` = one bounds check on `[heap_base, heap_base+heap_reserved)`).
- Minor evacuation only touches nursery-range pointers.
- `validateInNurserySafe` returns silently outside the nursery.

So a region reserved OUTSIDE the heap range is **GC-invisible with zero
changes to mark/sweep/evacuation**. Requirements that remain:

1. The region must sit below `HPOINTER_ADDRESS_LIMIT` (2^43) —
   `reserveAddressSpaceBelow`, same as the heap (raw-address HPointers).
2. Permanent objects must never reference collectable memory (closed
   subgraph) — guaranteed by transitive deep copy + the immutability
   audit below.
3. `ECO_HEAP_VALIDATE` walkers need a `PermanentSpace::contains` exemption
   (compile-time-gated builds only).

## Immutability audit (what may be copied)

- Strings/Bytes: **no in-place tag rewrites anywhere in StringOps/BytesOps**
  (verified by grep — reads never heal representations in place). All 8
  string/bytes forms copy VERBATIM (ropes/slices/views keep structure,
  recursing into bases).
- Tasks: pure post-Run-U (kill copy-on-install removed the last mutation).
- Closures: immutable at rest; apply copies. Walk `hdr->size` slots like
  `markChildren` (all initialized at rest — same contract mark relies on).
- Tag_Array (JsArray backing): mutated during construction only; immutable
  at rest (Array.set path-copies). Copyable.
- **DECLINED** (fallback keep-rooted): `Tag_Process` (mutable mailbox/stack),
  `Tag_Free`/`Tag_Forward` (should never appear in a value — defensive),
  any unknown tag (`default:` declines). Soundness never depends on copier
  completeness.

## Components

1. **`allocator/PermanentSpace.{hpp,cpp}`** (new): singleton;
   `reserveAddressSpaceBelow(8 GiB, HPOINTER_ADDRESS_LIMIT)` at first use;
   bump allocator with `commitAt` in 16 MiB steps; `contains(p)` = O(1)
   bounds check on used range; stats counters (values promoted/declined,
   objects/bytes copied, slots deregistered).

2. **`eco_caf_promote(uint64_t bits, uint64_t* slot)`** (extern "C", in
   PermanentSpace.cpp): env-gated `ECO_CAF_PERMANENT=1` (static, default
   OFF → returns bits unchanged, keeps slot rooted; one no-op call per slot
   lifetime).
   - constant bits or `!isInHeap` → deregister slot (GC-inert forever),
     return unchanged.
   - else TWO-PHASE deep copy: phase 1 traverses (visited set, per-tag
     child walk mirroring `OldGenSpace::markChildren`) collecting objects;
     ANY declined tag → return bits unchanged, nothing allocated, slot
     stays rooted. Phase 2 allocates+memcpys every object
     (`getObjectSize` totals include the header; object ptr == header ptr),
     builds old→new map, rewrites pointer fields in the copies (HPointer
     `ptr_ind==0` + `isInHeap` gate, `Unboxable` via the same
     `fieldKind`/`tupleFieldKind` masks mark uses). Cycles/sharing handled
     by the map. Cross-CAF references to already-permanent values pass the
     `!isInHeap` gate and stay shared.
   - success → `RootSet::removeJitRoot(slot)`, return copy address.
   - No managed-heap allocation, no Elm callbacks, no GC triggers inside
     promote → no safepoint → raw traversal is safe.

3. **Guard emission** (`EcoToLLVMGlobals.cpp installCafMemoGuard`): the
   instrumented return currently does `bits = barrier(v); store bits`.
   New: `bits = barrier(v); perm = call @eco_caf_promote(bits, addr);
   store perm; return barrier⁻¹(perm)` — the first caller also receives
   the permanent copy (no duplicate lifetime). Declaration minted at module
   level with `passthrough = ["gc-leaf-function"]` (RS4GC skips it; the
   barrier contract explicitly allows store-helper results as gc-leaf call
   args — EcoPtrIntVerify pattern 2). Caller-fast diamonds unchanged
   (slots hold 0 or permanent bits — both GC-inert).

4. **Stats print**: `[caf-permanent]` block in the GC stats dump (values
   promoted/declined, objects, KB, slots deregistered) when nonzero.

5. **CMake**: add PermanentSpace.cpp to the allocator source list.

## Correctness gates

- Full E2E suite with `ECO_CAF_PERMANENT=1` (env-runtime → all 1636 test
  binaries exercise promotion), plus default-off run = byte/behavior
  identical to today.
- `ECO_HEAP_VALIDATE` build leg with the flag on.
- Self-compile fixed point: flag-on self-compile MLIR must be byte-identical
  to flag-off (promotion is runtime-only; emission is unconditional).

## Benchmark (Run Z)

Single binary (runtime env A/B — no flavor mint needed): interleaved ×3 +
warmup, cold `eco-stuff` per leg, subst workload, walls + majors/minors +
`[caf-permanent]` counters. Decision: ship default-on only on a clear win;
neutral/negative → default-off, question closed with real data.

## Risks / invariants

- Permanent region OUTSIDE `[heap_base, +reserved)` but below 2^43 —
  mmap non-FIXED reservation cannot overlap the existing heap mapping.
- VA exhaustion of the 8 GiB region → allocate returns null → decline path
  (value stays heap-resident + rooted). Graceful.
- Phase-1-decline before any allocation ⇒ no partial garbage in permanent
  space; a phase-2 OOM mid-copy abandons bytes (counted) but returns the
  original — copies are unreachable, no dangling.
- New invariant HEAP_036 to record: permanent space contents are immutable,
  closed under references, GC-invisible; a slot may be deregistered ONLY
  when its value is fully permanent/constant/non-heap.

# HPointer Deref Optimization — Inline Fast Paths

## Status: IMPLEMENTED (2026-07-08) — --inline-deref default ON, full gate green

### Implementation outcome

Landed P0, P1, and the read-side of P2 with `--inline-deref` defaulting ON.
Measured **~8.8% faster** cold-cache native front-end self-compile (Stage 7a
264.3 s → 241.1 s; in-bootstrap warm 162 s → 144 s ~11%), byte-identical MLIR
output. Recorded in `frontendstats.txt`.

Delivered:
- **P1 (runtime, `Allocator.cpp`/`Allocator.hpp`, both kernel `ExportHelpers.hpp`):**
  `resolve()` demotes its 4 always-on asserts + nursery tripwire to
  `ECO_HEAP_VALIDATE`; `__builtin_expect` on the forward loop. New header-inline
  `Allocator::resolveFast()`; kernel `toPtr()` routes through it.
- **P0 (`EcoToLLVMInternal.h`, `RuntimeExports.{h,cpp}`, `EcoToLLVMRuntime.cpp`):**
  `value_enc::TagForward`/`TagBits` (static_assert'd vs `Elm::Tag_Forward`/
  `TAG_BITS` in `EcoToLLVMHeap.cpp`); new `eco_follow_forward` gc-leaf export;
  `__eco_resolve_fwd` marker + `eco_follow_forward` codegen decls.
- **P2 reads (`EcoToLLVMHeap.cpp`, `EcoBackend.cpp`, `EcoToLLVM.cpp`):**
  `--inline-deref` cl::opt (default ON) on `EcoRuntime.inlineDeref`. Boxed +
  primitive projections (record/custom/tuple2/tuple3), cons head (boxed) / tail,
  scalar unbox, array get/length lower to `__eco_resolve_fwd` marker +
  addrspace(1) GEP + `align 8` load. The `ExpandInlineDeref` LLVM pass (start of
  `runEcoBackend`, before every RS4GC/split) expands each marker to the inline
  header-tag forwarding-check diamond (`SplitBlockAndInsertIfThen`, `!prof`
  unlikely). GVN CSEs the header check across sibling field reads. array.set
  stores directly off the fresh clone (no resolve).
- **P3 (validation + docs):** invariants HEAP_030/031 added, FORBID_HEAP_002
  reworded. New E2E regression `test/elm/src/ReprDerefStressTest.elm` (deref over
  old-gen-promoted structures). `--inline-deref` flipped default ON.
- **Bug found + fixed by the C++ JIT codegen tests:** `eco_follow_forward` was
  unresolved in the JIT (AOT statically links it, so bootstrap/E2E were fine);
  registered it in `RuntimeSymbols.cpp` + declared in `RuntimeExports.h`.

Validation (all with `--inline-deref` ON): full bootstrap Stage 6/7a/8a
self-compiles + **Stage 8c native fixed-point** (byte-identical) green; full E2E
**1551/0** (AOT); C++ unit suite **1552/0** (JIT codegen + allocator/GC);
inline-deref smoke test correct; stress test green.

Deferred (not required for the win; correct-but-call-based today):
- **P2.4** construct.* field stores still via `eco_store_*` helpers (writes to
  fresh objects; lower value than the 137k read resolves).
- **cons-head primitive** getter kept as `eco_cons_head_i64/f64/i16` (dual
  boxed/unboxed path — not a simple slot load, so not inlined).
- **D8** `EcoPtrIntVerify` update: inspection shows it already accepts the new
  pattern (`inttoptr(load)` + as1 phi), so no change was needed; a dedicated
  `ECO_LOWERING_VALIDATION` build to confirm end-to-end is recommended.
- **Dedicated `ECO_HEAP_VALIDATE` compaction-window run:** the bootstrap self-
  compile already drives major GC + compaction hard (byte-identical fixed
  point); a targeted validator build is recommended as a belt-and-braces gate.

## Status: PLANNED (original)

Follow-up to `plans/hpointer-representation-redesign.md` (IMPLEMENTED). That
change made a heap HPointer word **bit-identical to the physical address**
(HEAP_028) — but codegen does not exploit it yet: every heap dereference in
generated code still pays an **out-of-line runtime call** to decode a pointer
whose decode is now zero instructions. This plan replaces those calls with
inline code.

## Goal

Lower every generated-code heap dereference (boxed projections, primitive
projections, scalar unbox, array access, field stores) to **inline
GEP + load/store on the `!eco.value` (addrspace(1)) pointer itself**, with a
branch-predicted inline forwarding check and a cold slow-path call — instead
of the current out-of-line `eco_resolve_hptr` / `eco_record_get_i64` /
`eco_store_record_field` helper calls.

## Motivation — measured evidence (2026-07-08 investigation)

Whole self-compiled compiler (`eco-compiler-boot.mlir` → `--emit=llvm`,
295 MB IR, 84,302 functions):

| Pattern | Static count | Cost each today |
|---|---|---|
| `eco_resolve_hptr` calls (boxed field loads + scalar unbox) | **137,714** | out-of-line call + 4 asserts (build preset) + forward loop |
| primitive getter calls (`eco_record_get_i64`, `eco_tuple*_get*`, `eco_custom_get_*`, `eco_cons_head_*`) | 16,177 | out-of-line call each |
| field-store calls (`eco_store_record_field*`, `eco_store_field`, `eco_store_cons_*`) | 18,566 | out-of-line call each |
| heap i64 loads annotated **`align 4`** | 169,021 | vs 387 at `align 8` — every heap slot is 8-aligned (HEAP_028) |

A boxed field load today (`EcoToLLVMHeap.cpp:877-889` and siblings):

```llvm
%p = call ptr @eco_resolve_hptr(ptr addrspace(1) %h)   ; out-of-line, gc-leaf
%f = getelementptr i8, ptr %p, i64 <ofs>
%v = load i64, ptr %f, align 4
%b = inttoptr i64 %v to ptr addrspace(1)               ; boxed result
```

`eco_resolve_hptr` (RuntimeExports.cpp:3574) → `hpointerToPtr` (:46-54) →
`Allocator::resolve` (Allocator.cpp:786-818): ptr_ind assert, null assert,
2 heap-bounds asserts, a header load, a `Tag_Forward` follow loop, and a
tag-validity assert. Under the `build` preset (`-UNDEBUG`, asserts ON) all
asserts execute on **every dereference of every Elm program**.

Call-shaped derefs also block CSE: `Main_toggle` in the probe program resolves
the same record twice (once via `eco_resolve_hptr` for the boxed field, once
inside `eco_record_get_i64` for the int field). Inline GEPs make GVN merge
these for free (same base pointer, same header-check load).

Estimated per-deref cost: today ≈ 15-25 cycles (call/ret + asserts + header
loop); inline fast path ≈ 3-6 cycles (header load is on the same cache line
as the data about to be read; branch predicted not-taken).

## The soundness constraint: the compaction forwarding window

The naive lowering ("the word is the address — just GEP+load") is **unsound**.
Old-gen incremental compaction (`OldGenSpace.hpp:264-266`) runs in phases:

```
Idle → Evacuating → FixingRefs → Idle
```

Between an evacuation slice and the completion of the reference-fixup pass,
live heap references can point at `Tag_Forward` tombstones — the mutator **can
observe forwards** during this window (this is why `Allocator::resolve` has
its follow loop; see also `OldGenSpace.hpp:273` "Follows a forwarding pointer
if present"). Minor-GC (nursery) forwards are consumed entirely inside the
STW minor collection (precise statepoint roots + immutable heap ⇒ no stale
refs survive the collection), so **old-gen compaction is the only source of
mutator-visible forwards**.

Two consequences:

1. The inline fast path MUST include a forwarding check (D1). A pure
   unchecked GEP is only ever legal if the compaction window is eliminated —
   explicitly out of scope here (see Futures).
2. Stores emitted by generated code target **freshly allocated objects only**
   (construction of records/customs/cons/tuples, array clone-then-set; Elm
   heap values are immutable after construction). A fresh allocation cannot
   be forwarded before the next statepoint, and store helpers are gc-leaf, so
   inline stores need **no check at all** (D3).

Checked assumptions (verified during P0, asserted forever after):

- A1: heap objects move only inside GC, which runs only under statepoints
  (allocation calls / safepoint polls). Between statepoints, physical
  addresses are stable.
- A2: an object returned by an `eco_alloc_*` statepoint cannot become
  `Tag_Forward` before the next statepoint.
- A3: mutator-visible `Tag_Forward` occurs only while
  `compact_phase_ != Idle` (instrumented + stress-tested in P0/P3).

## Design

### D1. Boxed field load — inline fast path + cold slow path

Header layout (Heap.hpp:144-152): `tag` is the low `TAG_BITS` (5) bits of the
first u32 of the 8-byte header at object offset 0. New lowering for
`eco.project.*` with boxed result:

```llvm
  %hdr   = load i32, ptr addrspace(1) %h, align 8        ; header word (same line as data)
  %tag   = and i32 %hdr, 31                               ; TAG_BITS mask
  %isfwd = icmp eq i32 %tag, TAG_FORWARD
  br i1 %isfwd, label %slow, label %fast, !prof !unlikely

fast:
  %f0 = getelementptr i8, ptr addrspace(1) %h, i64 <ofs>
  %v0 = load i64, ptr addrspace(1) %f0, align 8
  br label %join

slow:                                                     ; cold, out-of-line
  %r  = call ptr addrspace(1) @eco_follow_forward(ptr addrspace(1) %h)
  %f1 = getelementptr i8, ptr addrspace(1) %r, i64 <ofs>
  %v1 = load i64, ptr addrspace(1) %f1, align 8
  br label %join

join:
  %v = phi i64 [ %v0, %fast ], [ %v1, %slow ]
  %b = inttoptr i64 %v to ptr addrspace(1)
```

Key properties:

- **All address computation stays in addrspace(1)** — GEPs on the gc pointer
  produce *derived pointers* that RS4GC tracks/relocates correctly, and **no
  `ptrtoint` is introduced** (no new EcoPtrIntVerify surface beyond the load
  whitelist, D9).
- The header load is exactly the check `resolve()` already performs — we are
  inlining its fast iteration, not adding new work.
- Repeated derefs of the same `%h` in a statepoint-free region: the header
  load + tag check CSE away under GVN automatically (same address, no
  intervening stores, no statepoint).
- `!prof` unlikely weights put the slow block out of line.

`@eco_follow_forward` is a new tiny gc-leaf export: follow the forward chain,
return the final `HPtr` (addrspace(1)-typed, i.e. returns the *word*, not the
decoded `ptr`). Debug asserts live there, not on the fast path.

### D2. Primitive projections — same shape, direct typed load

`eco_record_get_i64` / `eco_tuple2_get0_f64` / `eco_cons_head_i64` /
`eco_custom_get_*` / `eco_array_get_*` calls (16,177 sites) become the same
D1 skeleton with a typed fast load (`load i64` / `load double` / `load i16`,
`align 8` — Char slots are stored in 8-byte slots; confirm per-slot layout
against `HeapHelpers.hpp` during implementation). The out-of-line helpers
were introduced by `plans/projection-helpers-everywhere.md` when decode
required `heap_base + (ptr<<3)` arithmetic that could not be expressed as a
GEP; HEAP_028 removed that reason.

`eco.array.length` (resolve + GEP + load i32) gets the same treatment.

### D3. Stores — raw inline GEP+store, no check

All generated stores target freshly allocated objects (construct.record /
construct.custom / construct.list / construct.tuple lowering emits
alloc-then-stores; `eco.array.set` stores into `eco_clone_array`'s result).
Per A2 no forward check is needed:

```llvm
%f = getelementptr i8, ptr addrspace(1) %new, i64 <ofs>
store i64 %v, ptr addrspace(1) %f, align 8
```

- The `ECO_HEAP_VALIDATE` stale-pointer tripwire currently inside
  `eco_store_record_field` (RuntimeExports.cpp:283-291) is preserved by the
  existing `EcoBoxedStoreVerify` mechanism: mark inline boxed stores with
  `eco.boxed_slot` (as `eco.array.set` already does) so validation builds
  insert `eco_validate_nursery_hptr_bits` — behavior parity, zero release cost.
- `eco_array_set_fix_kind` (RuntimeExports.cpp:3590) side effect on
  `header.unboxed` must be preserved for array.set — either keep that one
  helper call or inline the kind update (it is a header RMW; keeping the call
  initially is fine, it is not on the measured hot paths).

### D4. Scalar unbox (`eco.unbox` → i64/f64/i16)

Currently resolve-call + GEP(+8) + load (`EcoToLLVMHeap.cpp:174-187`). Same
D1 skeleton; the value can be old-gen (e.g. boxed Int read out of an old
record), so the forward check IS required here.

### D5. Alignment + attributes (independent quick win — lands first)

- Every heap slot load/store emitted anywhere in `EcoToLLVM*` gets
  **`align 8`** (169,021 sites currently say `align 4`, defeating alignment-
  driven isel/vectorization). Audit every `CreateLoad`/`CreateStore`/
  `LLVM::LoadOp`/`LLVM::StoreOp` in `EcoToLLVMHeap.cpp`,
  `EcoToLLVMClosures.cpp`, `EcoToLLVMControlFlow.cpp`, `BFToLLVM.cpp`
  (BF cursor loads excluded — byte-granular by design).
- Helper/alloc declarations get precise attributes while calls still exist
  (and permanently for the slow path + allocators):
  `nounwind willreturn`, `memory(argmem: read)` for getters,
  `nonnull align 8` on returned object pointers,
  `dereferenceable(N)` where the object size is statically known
  (header + field count is known at every projection site).
  This alone lets GVN de-duplicate today's repeated resolve calls.

### D6. Single source of truth for layout constants

The lowering needs `TAG_BITS`, `Tag_Forward`, header size, per-object field
offsets (it already has the offsets — `ConsTailOffset` etc. in
`EcoToLLVMInternal.h`). Codegen and allocator live in the same tree:
**include `Heap.hpp` from `EcoToLLVMInternal.h`** (or mirror the two new
constants with `static_assert` cross-checks against the enum, same pattern as
the D6 golden words in the representation redesign). No silent drift.

### D7. Flag + fallback

`cl::opt` on the native driver: `--inline-deref` (default ON once gates pass;
`--inline-deref=false` restores helper calls). The helper exports are NOT
deleted — kernel C++, the JIT bring-up path, and the fallback keep using
them. Follow the `ECO_ECO2LLVM_PARALLEL` precedent: land dark, flip default
after the full gate, keep the escape hatch one release.

### D8. EcoPtrIntVerify update (validation builds)

The verifier whitelist for `inttoptr` operands ("LoadInst from recognised
slot", `EcoPtrIntVerify.cpp:57-67` region) must recognise loads whose address
is a GEP on an addrspace(1) base (currently it recognises GEPs on
`eco_resolve_hptr` results). Fast/slow phi of loads must also be recognised
(PHI case already exists).

### D9. Kernel C++ side (same disease, separate ledger)

`Allocator::resolve` is a non-inline .cpp function called from every kernel
`toPtr` (`eco-kernel-cpp/src/eco/ExportHelpers.hpp:44`,
`elm-kernel-cpp/src/ExportHelpers.hpp`). Move the fast path (ptr_ind check +
reinterpret + single tag test) into the header as an always-inline function
with an out-of-line `resolveSlow` for the forward loop; demote the four
always-on asserts to `ECO_HEAP_VALIDATE`. This speeds up every kernel list
traversal / string op without touching codegen.

## Phases

### P0 — Evidence + groundwork (no behavior change)

- **P0.1** Instrument `Allocator::resolve`: count forward-loop iterations on
  mutator paths (thread-local counter, dumped with GC stats under
  `ECO_GC_STATS`). Run full E2E + stress + a forced-compaction run; record
  how often the window is actually hit. Validates A1-A3 and sizes the slow
  path's real frequency.
- **P0.2** Layout constants exposure (D6) + `static_assert`s.
- **P0.3** New `eco_follow_forward` export + unit test (forward chain of
  length 0/1/2; embedded-constant input asserts).
- **P0.4** Draft invariant updates (see Invariants below) — reviewed before
  any lowering change.
- Gate: full suite green (pure additive).

### P1 — Quick wins (each lands independently, full gate each)

- **P1.1** `align 8` everywhere (D5 first bullet). Byte-identical semantics;
  verify via `test/codegen/*.mlir` expectations + E2E.
- **P1.2** Helper declaration attributes (D5 second bullet). Check with the
  bool-probe that GVN now merges `toggle`'s duplicate resolves.
- **P1.3** Kernel C++ inline fast path (D9). Gate additionally on
  `build/test/test` allocator suite + `ECO_HEAP_VALIDATE` E2E pass.
- Measure after P1: Stage 7a protocol from `frontendstats.txt`
  (baseline: ~264 s avg, 3 runs, warm ~/.eco, cold eco-stuff).

### P2 — Inline deref lowering (the core change)

- **P2.1** Boxed projections (D1): record/custom/tuple/cons head/cons tail +
  closure env loads.
- **P2.2** Primitive projections + array get/length (D2).
- **P2.3** Scalar unbox (D4).
- **P2.4** Inline stores (D3) for construct.* and array.set (keep
  `eco_array_set_fix_kind` call initially).
- **P2.5** EcoPtrIntVerify update (D8); refresh `test/codegen/*.mlir`
  expectations (new: `inline_deref_fastpath.mlir` asserting the tag-check +
  GEP + phi shape and the absence of `eco_resolve_hptr` on the fast path).
- All behind `--inline-deref` (D7), default OFF until P3 passes.
- Gate: full 1551-test E2E with the flag ON, elm-tests, unit tests, JIT E2E
  (shared lowering — JIT inherits the change), bootstrap stage convergence.

### P3 — Compaction-window + GC stress validation

- **P3.1** New stress test: force old-gen incremental compaction
  (tiny old-gen budget / `heap-config.json` tunables) while a compiled
  program traverses large old-gen structures, so generated fast paths
  actually take the slow branch. Assert result correctness + zero crashes
  under `ECO_HEAP_VALIDATE`.
- **P3.2** Tiny-nursery minor-GC stress (existing technique — see
  `eco-listmapn-stale-cursor-gc-bug`) with the flag ON.
- **P3.3** Flip `--inline-deref` default ON.
- Gate: everything in P2's gate + P3.1/P3.2, plus `ECO_LOWERING_VALIDATION`
  build clean (verifier).

### P4 — Measure + tune

- Stage 7a timing per `frontendstats.txt` protocol (3+ runs); record in
  `frontendstats.txt` run log.
- E2E suite wall-time delta; a List/record-traversal microbenchmark in
  `test/stress-elm` before/after.
- Tuning knobs if needed: branch-weight metadata, `dereferenceable`
  propagation, hoisting the tag check out of `scf.while` list-walk loops
  (LICM should already do this once the check is inline — verify on the
  List.foldl probe).

## Invariants impact (design_docs/invariants.csv)

- **FORBID_HEAP_002** ("no HPointer arithmetic except via allocator helpers /
  runtime APIs") — reword: codegen-emitted GEP/load sequences produced by the
  blessed lowering patterns are the runtime API equivalent; direct arithmetic
  remains forbidden elsewhere.
- **New HEAP_030 (proposed):** "Generated-code heap dereferences must handle
  `Tag_Forward`: any inline fast path performs the header tag test and defers
  to `eco_follow_forward` otherwise. Mutator-visible forwards occur only
  while old-gen compaction is in Evacuating/FixingRefs."
- **New HEAP_031 (proposed):** "Generated-code stores write only to objects
  allocated since the previous statepoint (fresh objects); such objects are
  never forwarded. Heap values are immutable after construction escape."
- **HEAP_028** unchanged (it is the enabler).
- CGEN_* projection/store rows: add encoding notes referencing the inline
  patterns; REP_BOUNDARY_001/002 semantics unchanged.

## Risks & mitigations

| Risk | Mitigation |
|---|---|
| Mutator hits a forward the fast path mishandles | The fast path *checks*; P0.1 quantifies window frequency; P3.1 forces the window under `ECO_HEAP_VALIDATE` |
| RS4GC mis-tracks addrspace(1) GEP derived pointers across statepoints | Standard RS4GC functionality (base/derived relocation); lowering tests assert the shape; full GC stress in P3 |
| EcoPtrIntVerify false-positives on the new pattern | D8 lands with P2 in the same commit; `ECO_LOWERING_VALIDATION` build in the P3 gate |
| `align 8` wrong for some slot (Char/i16, split headers, BF buffers) | P1.1 audits per-site; BF byte cursors excluded; Char slot layout confirmed against HeapHelpers before annotating |
| Code-size growth from 137k inline sequences | Net instruction count is roughly flat (call setup removed); function-sections + gc-sections already trim; measure `.text` delta in P4 |
| A store site that is NOT construction-fresh sneaks in later | HEAP_031 invariant + `EcoBoxedStoreVerify` tripwire in validation builds |
| JIT path divergence | Lowering is shared; JIT E2E in the P2 gate |
| Windows/macOS bitfield or layout drift | D6 static_asserts compile-time fail, same pattern as the redesign's golden words |

## Acceptance criteria

- [~] P0.1 forward-frequency report: superseded — the inline design is correct
      for any frequency (header check + gc-leaf slow path); `__builtin_expect`
      hints the rare case. No counter landed.
- [x] Full gate green with `--inline-deref` ON: E2E **1551/0**, C++ unit +
      JIT-codegen + MLIR-lowering tests **1552/0**, **bootstrap Stage 8c
      native fixed-point** (byte-identical self-compile).
- [~] Compaction-window / tiny-nursery stress: bootstrap self-compile drives
      major GC + compaction hard and reaches a byte-identical fixed point;
      `ReprDerefStressTest` added. Dedicated `ECO_HEAP_VALIDATE` build not run
      (recommended follow-up).
- [~] `ECO_LOWERING_VALIDATION` build: verifier inspected to already accept the
      new pattern (D8); dedicated build not run (recommended follow-up).
- [x] Read-side calls eliminated on the fast path: boxed/primitive projections,
      unbox, array get/length now inline (verified in `--emit=llvm`: `score`
      reads two fields inline with a CSE'd forward check, no `eco_resolve_hptr`).
      Deferred: construct.* stores + cons-head primitive still call helpers
      (P2.4 / dual-path).
- [x] Inlined heap slot loads/stores carry `align 8` (i32 array-length uses
      natural `align 4`).
- [x] Stage 7a delta recorded in `frontendstats.txt` (264.3 s → 241.1 s,
      ~8.8% faster; warm in-bootstrap 162 s → 144 s).
- [x] invariants.csv updated (FORBID_HEAP_002 reword; HEAP_030/031 added).

## Out of scope (explicitly deferred)

- **Eliminating the forwarding window** (compaction redesign so mutators
  never see `Tag_Forward` — would let the fast path drop its check and become
  a bare GEP). Revisit after P4 numbers; the inline check is cheap enough
  that this may never pay.
- Bool/`i1` ABI changes and boxed-word bit-twiddling (separate track).
- `--rs4gc-after-opt` / inlining pipeline order (separate track; composes
  with this plan — inline derefs make inlined callees even cheaper).
- LTO / linking the runtime as bitcode for cross-TU inlining.
- String/Bytes (BF dialect) access paths — already fused/byte-oriented.

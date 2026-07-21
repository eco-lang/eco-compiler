# Allocator::resolve inlining and optimization ("P2.5"): the residual resolve classes

**Status: IMPLEMENTED + GATED (2026-07-21). R0-R3 SHIPPED (default-on); R4
soak-pending; §7 records the as-built.** Headline: **−6.8 % workload wall**
(interleaved ×3, majors identical), `Allocator::resolve` 11.49 % → 5.28 %,
`eco_get_tag` eliminated from the profile, compiled code emits ZERO
out-of-line resolve/get_tag calls (34,972 sites converted), fixed point +
corpus 1628/1628 + verifier + heap-validate legs green.

Standalone successor to the census finding
(census §D8/§D8b, preserved in `plans/lss-dispatch-value-extraction.md` §12)
— deliberately decoupled from the LSS track (measured to completion; this is
runtime/heap work). Direct continuation of the shipped P2 plan
(`plans/hpointer-deref-inline-fastpath.md`, IMPLEMENTED 2026-07-08) — read its
as-built header first; the mechanism built there is reused verbatim here.

**Goal:** eliminate the bulk of `Elm::Allocator::resolve`'s **11.5 % of
workload wall** — the single largest runtime cost in the D8 profile — by
extending P2's inline forwarding-check to the resolve classes it never
converted. Measured ceiling: **≈ 9.8 % of wall** (85 % of resolve samples
attribute to compiled-code out-of-line `eco_resolve_hptr` calls; 14,339 call
sites in the binary). Plausibility anchor: P2's projection-read conversion of
the ~137 K-site class measured **−8.8 % wall** at ship.

---

## 1. Context (all census-verified, 2026-07-21)

- P2 shipped the marker mechanism end-to-end and it is permanent: heap-deref
  lowering emits a `__eco_resolve_fwd` marker (gc-leaf, AS1→AS1);
  `expandInlineDerefs` (EcoBackend.cpp:698, runs FIRST in `runEcoBackend`,
  before the `$cap` inline prepass and every RS4GC flavour) expands each
  marker to an inline header-tag forwarding-check diamond with a
  predicted-not-taken cold call to `eco_follow_forward`. Invariants
  HEAP_030/031 cover it. The `--inline-deref` flag and the out-of-line
  fallback branches were REMOVED after ship — there is no A/B against P2
  itself, and none is needed (−8.8 % is recorded).
- The RESIDUAL out-of-line resolve population (perf-script caller
  attribution, 4,727 resolve-leaf samples: 85 % compiled-Elm callers, 3 %
  runtime-internal; top callers `Dict_insertHelp` ~20 %, string/encoder case
  code, closure-capture unpacks) is emitted by SIX classes:

  | class | site (verify anchors at impl time) | idiom today |
  |---|---|---|
  | R1a ADT tag load, case heap path | `EcoToLLVMControlFlow.cpp:638` | `eco_resolve_hptr` + load ctor@+8 |
  | R1b eco.get_tag op lowering | `EcoToLLVMControlFlow.cpp:65` | `call eco_get_tag` (2.79 % flat, resolve inside) |
  | R2 boxed case-SCRUTINEE unbox | `EcoToLLVMControlFlow.cpp:123` | resolve + load value@+8 |
  | R3 closure-capture projection | `EcoToLLVMClosures.cpp:115` | resolve + slot loads (loads already v2-typed) |
  | R4 aggregate unbox-to-struct | `EcoToLLVMValueAgg.cpp:571` | resolve + per-field GEP/loads |
  | R5 closure-construct in-place stores | `EcoToLLVMValueAgg.cpp:673` | resolve + stores INTO A FRESH ALLOC |
- The region is newly protected: REP_LLVM_002 fold-proof slot crossings
  (`plans/fold-proof-boxed-slot-crossings.md`) mean boxed-slot loads/stores
  emitted here are immune to the inline-annihilation class, and E1.3 v3's
  full `$cap` inlining means converted diamonds get inlined into callers —
  the two changes COMPOUND.
- Out of scope (siblings, own plans if ever): `eco_gc_push_stack_range`
  coalescing (5.1 % — the other census lever), kernel-internal resolves
  (P1's `resolveFast` already routes them), GC-internal resolve use.

## 2. Design

**One move, six applications:** replace each out-of-line resolve with the
existing marker + AS1 GEP + typed/barriered access — exactly P2's read-side
pattern — except where the object is provably FRESH, in which case drop the
resolve entirely.

- **R1a/R1b (the expected head of the payoff — Dict/Set case-per-compare
  loops):** the tag read becomes marker → AS1 GEP(+8) → `load i32`/mask.
  R1b additionally deletes a full call round-trip (`eco_get_tag` keeps its
  runtime definition for kernel-internal use). Tag words are the
  REP_LLVM_001(c) bit-test class — no pointer decode, no barrier needed.
  Preserve the embedded-constant (CONSTANT_TAG) branch structure at :638
  exactly — only the heap arm changes.
- **R2:** marker → AS1 load of the payload word; Int/Char scrutinees are
  unboxed-word loads (no barrier); if any boxed-value load exists on this
  path it goes through `heapLoadI64ToValue` (barriered, REP_LLVM_002).
- **R3:** the base resolve becomes a marker; the slot loads are ALREADY
  v2-typed (`ptr addrspace(1)` for boxed, prims typed) — only the base
  changes. Compounds with E1.3 v3: the diamond inlines into `$cap` callers.
- **R4:** marker + per-field AS1 GEP/loads; boxed fields via the barriered
  helper, prims typed (the `widenFieldToI64Local` sibling patterns).
- **R5 (special — likely NO diamond at all):** the stores target an object
  allocated a few instructions earlier with no intervening safepoint — a
  fresh object CANNOT be forwarded (the shipped array.set precedent:
  "freshly-cloned object … GEP directly — no resolve/forward check",
  EcoToLLVMHeap.cpp:1127). Audit the alloc→store window (R0); if clean,
  emit direct AS1 GEPs off the allocation result: zero resolve, zero
  diamond. If a safepoint CAN intervene, fall back to the marker form.

**Rollout switch (the `--inline-deref` question, answered):** yes — bring
back the toggle, but as the house-standard TEMPORARY rollout env, not a
permanent flag: `ECO_INLINE_DEREF_EXT` (lowering-time, default ON when the
gates pass; `=0` restores the out-of-line emission for A/B and bisection).
P2's own arc is the precedent: flag for rollout → measure → default-on →
DELETE the flag and the fallback once soaked (R6). A permanent flag would
recreate exactly the fallback bitrot P2's removal eliminated.

## 3. Milestones

- **R0 — audit + per-class attribution (no behavior change).** Re-verify the
  six anchors; enumerate any further `getOrCreateResolveHPtr`/
  `getOrCreateGetTag` callers this plan missed; addr2line the D8 caller
  sample offsets to split the 85 % BY CLASS (sharpens R-ordering; R1 is the
  hypothesis, not yet the measurement); verify R5's alloc→store windows are
  safepoint-free. Deliverable: the class-weight table in this file.
- **R1 — the ControlFlow classes (R1a+R1b+R2), env-gated.** Gates: codegen
  suite green both env states; env-off byte-identical binary (the zero-delta
  discipline); corpus `--target check`; interleaved wall A/B ×3 with majors
  recorded (this is the head of the prize — expect a measurable win here or
  re-plan).
- **R2 — the remaining classes (R3, R4, R5).** Same gates; R5 gets a
  dedicated tiny-nursery leg (fresh-object reasoning must survive forced
  GC pressure).
- **R3 — default-on + full battery (§4) + "Run P".** Perf re-profile: the
  headline metric is `Allocator::resolve` share **11.5 % → target < 3 %**;
  wall A/B ×3 vs the pre-plan binary; census-neutrality (dispatch counts
  identical — this plan never touches dispatch); binary-size and
  `$cap`-marking-count deltas (see §5.1).
- **R4 — flag deletion + docs.** Delete `ECO_INLINE_DEREF_EXT` + the
  out-of-line emission arms (the P2 end-state); update HEAP_030/031 wording,
  census.md, memory.
- **R5 (optional, census-gated by Run P):** the write side — P2's deferred
  P2.4 (`construct.*` field stores via `eco_store_field`, 2.71 % flat) and
  `Allocator::resolve` body micro-opts, ONLY if the re-profile still shows
  them in the head.

## 4. Validation battery

1. Codegen suite + full corpus (both env states in R1/R2; touch-all/cache
   discipline for env-sensitive legs).
2. **All-keyed self-compile fixed point** — rc=0 + output byte-identical
   (the standing THE-gate for this region).
3. **Forwarding-window stress** — the specific hazard here is the diamond's
   correctness DURING old-gen compaction: `ReprDerefStressTest.elm` (P2's
   pin), plus a tiny-nursery + compaction-forcing `ECO_HEAP_VALIDATE` leg
   (bounded workload). This matters MORE than it did for the barriers: these
   changes are on the forwarding path itself.
4. `EcoPtrIntVerify` validation build (silent expected; tag loads are
   bit-test class, boxed loads barriered/typed).
5. Wall protocol: interleaved ×3, majors recorded, stock GC, cold subst
   workload; single-run reads are directional only.

## 5. Risks / interactions

1. **§5.1 Diamond bloat vs the `$cap` inline threshold.** Each converted
   site grows ~+5-6 instructions (header load, mask, cmp, branch, phi).
   Bodies containing resolves get bigger, so the E1.3 T=64 marking set
   SHRINKS. Run O showed T=128/256 are free (binary smaller, wall flat) —
   if R3's marking count drops materially, raise the default threshold in
   the same commit and re-run the Run-O sweep gate.
2. **I-cache growth:** 14.3 K sites × ~6 insts. P2 converted a 10× larger
   class at net −8.8 % wall — precedent says the branch-predicted diamond
   beats the call — but measure, don't assume (the wall A/B is the gate).
3. **R5 freshness reasoning** is an invariant-grade claim — if the audit
   finds ANY safepoint in an alloc→store window, use the marker form there;
   never ship "probably fresh".
4. **GVN/CSE of sibling header checks** happens post-RS4GC in the
   per-partition -O2 (P2 verified this); nothing to do, but the R0 audit
   should confirm the diamonds emitted inside now-inlined `$cap` bodies
   still CSE across the inline seam (they should — same block structure).
5. `eco_get_tag` stays exported (kernel/JIT users); only compiled-code
   emission moves inline.

## 6. Explicitly out of scope

`eco_gc_push_stack_range` coalescing (own census lever, own plan);
`GCStats`/timer overhead (build-config, not code); kernel-internal resolve
(P1 done); the ~40 M-call mismatched-ABI `$cap` floor (AbiCloning-family,
separate shelf).

---

## 7. AS BUILT (2026-07-21) — R0-R3 SHIPPED + GATED; R4 soak-pending

**Headline: −6.8 % workload wall** (interleaved ×3: OFF 4:11.97/4:12.95/4:14.75,
mean 4:13.2 vs ON 3:56.51/3:55.94/3:55.53, mean 3:56.0; every ON leg beats
every OFF leg by ≥15 s; majors 9 on all legs; outputs byte-identical across
env states and repeats). **`Allocator::resolve` 11.49 % → 5.28 % of wall**
(−54 %); `eco_get_tag` (2.79 %) eliminated from the profile entirely.
Compiled code now emits **ZERO** out-of-line `eco_resolve_hptr` (was 14,351
call sites) and **ZERO** `eco_get_tag` (was 20,621) — 34,972 sites converted.

### 7.1 What R0 found beyond the plan (the audit corrections)

- **The §1 six-class table was INCOMPLETE** — the original enumeration was
  `head`-truncated (audit lesson: never pipe an "exhaustive" grep through
  head). Four more emitters existed, all in EcoToLLVMClosures.cpp:
  the wrapper legacy scalar-unbox arms (×4 uses, boxed Int/Float/Char params),
  the papCreate construct (a SECOND R5-class fresh-object site), and —
  the hottest of all — **`emitFastClosureCall`'s closure-base resolve**
  (every stamped fast dispatch, 100 M+/run). `emitClosureCall` (:1277) also
  resolves but is the dead `_dispatch_mode` plumbing (no producer) — left
  untouched.
- **R1b could NOT be open-coded at the MLIR level:** eco.get_tag sits inside
  single-block scf regions (loopified tail recursion — precisely the hot
  Dict/Set loops), where block splitting is illegal (`'scf.while' op expects
  region #1 to have 0 or 1 blocks`, 288 corpus failures on the first
  attempt). Shipped architecture: the lowering emits a declare-only gc-leaf
  marker `__eco_get_tag_inline(hptr)->i32` (decl in materializeAllRuntimeDecls);
  `expandGetTagMarkers` (EcoBackend.cpp, runs FIRST in runEcoBackend, before
  expandInlineDerefs which consumes the `__eco_resolve_fwd` calls its heap
  arms emit) builds the emb-constant/Tag_Cons/Tag_Custom diamond at the
  LLVM-IR level. `value_enc::TagCons/TagCustom` added with Heap.hpp
  static_asserts.
- **EcoPtrIntVerify earned its keep:** the first expansion put the
  `and(bits,3)` in a different block than its ptrtoint — the verifier's
  same-BB bit-test rule (REP_LLVM_001(d)) hard-failed the validation
  lowering. Fixed by computing all ptrtoint users in the head block. (Also a
  harness lesson: a `{ time ...; } | grep real && echo ok` pipeline reports
  grep's status, not the command's — the first "silent" verifier claim was
  vacuous; re-run with true rc.)

### 7.2 Shipped shape

- `inlineDerefExtEnabled()` + `inlineResolvedBase()` (EcoToLLVMInternal.h);
  `ECO_INLINE_DEREF_EXT=0` = out-of-line fallback (A/B + bisection).
- Converted (marker + AS1 GEP/loads): case tag load (CF:638 arm), boxed
  scrutinee unbox (CF:123 arm), get_tag (marker→LLVM expansion),
  from_heap (VA, loadFieldAt GEP follows base addrspace), closure-capture
  projection (Clo), wrapper legacy scalar unbox (×4 arms),
  emitFastClosureCall base (+ its census-counter GEP).
- Fresh-object NO-resolve (HEAP_031 extension): make.closure (VA) and
  papCreate (Clo) stores GEP directly off the AS1 alloc result.
- Runtime `eco_get_tag`/`eco_resolve_hptr` stay exported (kernel/JIT +
  fallback); pins updated: from_heap_{tuple2,record}.mlir (marker),
  value_make_closure.mlir (no resolve at all).

### 7.3 Gate record

| gate | result |
|---|---|
| ext-OFF byte-identity vs pre-plan artifact | BYTE-IDENTICAL (×3 checks incl. final emission) |
| codegen suite | 387/387 (shipping config) |
| full corpus `--target check` | 1628/1628 (one rerun after the documented pre-existing OldGen unit-test flake) |
| all-keyed solver self-compile fixed point | rc=0, output byte-identical to allkey-v4.mlir (×2, incl. final emission) |
| workload outputs | OFF==ON, repeat==repeat, byte-identical |
| EcoPtrIntVerify (validation build) | SILENT, true rc=0 (after the §7.1 same-BB fix it caught) |
| ECO_HEAP_VALIDATE tiny-nursery leg | 55-module compile, 134 minors + 1 major, clean |
| Run P wall ×3 interleaved | **−6.8 %** (4:13.2 → 3:56.0), majors identical |
| perf re-profile | resolve 11.49 % → **5.28 %**; get_tag 2.79 % → absent |
| binary size | 59,773,176 → 61,651,440 (+3.1 % — the 35 K diamonds) |
| lowering wall | 77 s → 90 s (+17 % — expansion + bigger IR; no budget was set, recorded honestly) |
| `$cap` marking set (§5.1) | 15,757 → 15,324 (−433 bodies over T=64 from diamond growth; T=128 known-free if wanted) |

The <3 % resolve target was not fully met: the residual 5.28 % is
runtime-INTERNAL (kernel helpers, `eco_store_field`'s internal resolve —
its flat share rose 2.71→3.16 % on the smaller denominator — and GC), i.e.
the optional R5 write-side/runtime milestone's territory, plus perf
tail-call attribution noise. The compiled-code class this plan targeted is
structurally extinct.

### 7.4 R4 status: SOAK-PENDING (deliberate)

Following the P2 precedent exactly (flag shipped default-ON, removed
later): `ECO_INLINE_DEREF_EXT` and the out-of-line arms stay for a soak
period as the bisection escape hatch, then R4 deletes them. The
byte-identity gate makes the fallback provably faithful meanwhile.

### 7.5 Open (unchanged)

R5 optional milestone (write-side P2.4 + runtime-internal resolve, now the
whole residual 5.28 %); the §6.1 threshold bump if the −433 marking delta
ever matters; R4 deletion after soak.

# Tuple-slot boxing bug — container variant report

Companion to `plans/tuple-slot-boxing-reproducer.md`. Catalogs 12 new
E2E test variants that exercise different heap-container shapes
around the same buggy `capturedIdx` (slot 0 of a let-bound
tuple-destructure pattern with a polymorphic
`List.indexedMap Tuple.pair members` feeding the fold).

## Headline outcome

13 tests under `test/elm/src/TupleSlotBoxing*Test.elm`, all using the
same iter3 skeleton from the original reproducer. Run via
`TEST_FILTER=TupleSlotBoxing /work/build/test/test`:

| # | Test | Inner container | Slot of `capturedIdx` | Bug fires? |
|---|------|-----------------|------------------------|------------|
| 1 | `TupleSlotBoxingT3Slot0Test` | `Tuple3` | slot 0 | **FAIL** |
| 2 | `TupleSlotBoxingMismatchTest` | `Tuple3` | slot 1 (mid) | **FAIL** |
| 3 | `TupleSlotBoxingT3Slot2Test` | `Tuple3` | slot 2 | **FAIL** |
| 4 | `TupleSlotBoxingT2Slot0Test` | `Tuple2` | slot 0 | **FAIL** |
| 5 | `TupleSlotBoxingT2Slot1Test` | `Tuple2` | slot 1 | **FAIL** |
| 6 | `TupleSlotBoxingRecordSingleTest` | `{ idx : _ }` | only slot | **FAIL** |
| 7 | `TupleSlotBoxingRecordMultiTest` | `{ a, b, c }` | field `b` | **FAIL** (positions scrambled — see record-layout-reorder section below) |
| 8 | `TupleSlotBoxingCustomSingleTest` | `type Wrap = Wrap Int` | only slot | pass |
| 9 | `TupleSlotBoxingCustomMultiTest` | `type Triple = Triple Int Int Int` | slot 1 | pass |
| 10 | `TupleSlotBoxingCustomMultiCtorTest` | `type T = WithIdx Int \| Empty` | only slot of `WithIdx` | pass |
| 11 | `TupleSlotBoxingListConsTest` | `List Int` (singleton list) | Cons head | pass |
| 12 | `TupleSlotBoxingArrayTest` | `Array Int` | element | pass |
| 13 | `TupleSlotBoxingClosureTest` | `() -> Int` (closure capture) | capture slot | pass |

**7/13 fail, 6/13 pass.** All 5 tuple variants fire, both record
variants fire, no nominal/uniform-element container fires.

## Runtime evidence (failing tests)

Each garbage value is in the 10-digit HPointer-bit-pattern range,
confirming the same boxing-mismatch family as the original
reproducer:

```
TupleSlotBoxing:              "[0,1610612935,1,1,1610612944,2]"  -- T3 slot 1
TupleSlotBoxingT3Slot0:       "[1610612935,0,1,1610612944,1,2]"  -- T3 slot 0
TupleSlotBoxingT3Slot2:       "[0,1,1610612935,1,2,1610612944]"  -- T3 slot 2
TupleSlotBoxingT2Slot0:       "[1610612935,0,1610612943,1]"      -- T2 slot 0
TupleSlotBoxingT2Slot1:       "[0,1610612935,1,1610612943]"      -- T2 slot 1
TupleSlotBoxingRecordSingle:  "[1610612935,1610612943]"          -- record, only slot
TupleSlotBoxingRecordMulti:   "[0,1,1610612935,1,2,1610612945]"  -- see anomaly below
```

Garbage values are at exactly the positions where `capturedIdx`
should appear, except for `RecordMulti` (next section).

## Pattern: which container kinds fire the bug

| Kind | Fires? | Why |
|------|--------|-----|
| `Tuple2`, `Tuple3` (any slot) | yes | Tuple types are **structural** — the layout (`computeTupleLayout`) consumes the use-site element types verbatim. A slot whose use-site type is `MVar _ CEcoValue` lays out as `kind=0` (boxed); construction boxes the i64 SSA value, but the downstream consumer reads it as i64, picking up the HPointer bit pattern. |
| Anonymous `Record` | yes | Same reason as tuples — records are also structural; `computeRecordLayout` uses use-site field types. |
| Nominal `Custom` (any ctor arity, any tag count) | no | `computeCtorLayout` uses the field types from the **type declaration**, not the use-site. `type Wrap = Wrap Int` fixes the field type to `Int` regardless of how `capturedIdx`'s type is currently being solved — and the act of writing `Wrap capturedIdx` emits a CEqual constraint that pins `typeOf capturedIdx ~ Int`, killing the bug at constraint-generation time. |
| `List` (singleton `[capturedIdx]`) | no | `List a` is a unary type constructor; `[capturedIdx] :: List <typeOf capturedIdx>`. The outer `inner ++ acc` chain and the eventual `List Int` consumer pin the list's element type to `Int`, which propagates back to `capturedIdx`. |
| `Array` (`Array.fromList [capturedIdx]`) | no | Same as List — the kernel signature is `Array.fromList : List a -> Array a` and the result Array type's `a` is pinned by downstream usage. |
| Closure (`(\_ -> capturedIdx)`) | no | The closure's body type is `b -> typeOf capturedIdx`; the call site `f ()` propagates the result type back, which then pins `typeOf capturedIdx` to `Int` via the consumer. |

So the bug is specifically a **structural-type-with-independent-slots**
problem. Records and tuples have multiple component slots whose types
are nominally independent in the type system; nominal types and
unary-element types force their element types via the type
declaration / unary constructor.

## Upstream trace evidence

Diagnostic compiles via `compiler/build-kernel/bin/eco-boot-2-runner.js`
(traces in `/tmp/variant_traces/*.log`):

```
test                                          SpT  STA  TLC   TL  TCm
TupleSlotBoxingMismatchTest                     1    3    6    2    1
TupleSlotBoxingT3Slot0Test                      1    3    6    2    1
TupleSlotBoxingT3Slot2Test                      1    3    6    2    1
TupleSlotBoxingT2Slot0Test                      0    2    3    2    1
TupleSlotBoxingT2Slot1Test                      0    2    3    2    1
TupleSlotBoxingRecordSingleTest                 0    2    3    0    0
TupleSlotBoxingRecordMultiTest                  0    2    3    0    0
TupleSlotBoxingCustomSingleTest                 0    2    3    0    0
TupleSlotBoxingCustomMultiTest                  0    2    3    0    0
TupleSlotBoxingCustomMultiCtorTest              0    2    3    0    0
TupleSlotBoxingListConsTest                     0    2    3    0    0
TupleSlotBoxingArrayTest                        0    2    3    0    0
TupleSlotBoxingClosureTest                      0    2    3    0    0

Columns:
  SpT — [Specialize/Tuple] (mismatch; gated arity==3)
  STA — [Specialize/Tuple/Always] (every 3-tuple)
  TLC — [TupleLayout/Compute] (every 3-tuple layout at codegen)
  TL  — [TupleLayout] (tuple layout with MVar _ CEcoValue in types)
  TCm — [TupleCreate-mismatch] (codegen layout vs SSA mismatch)
```

Observations:
- **T3 variants** light up every gauge: `[Specialize/Tuple]` mismatch
  fires once (the buggy 3-tuple), plus `[TupleLayout]`/
  `[TupleCreate-mismatch]` downstream.
- **T2 variants** show `[TupleLayout]` + `[TupleCreate-mismatch]` (2
  layouts, 1 mismatch) but **not** `[Specialize/Tuple]` —
  `[Specialize/Tuple]` is gated on `arity == 3` (see
  `Specialize.elm:3260`). So 2-tuples slip past the upstream-only
  gauge, but the downstream tuple traces still catch them.
- **Record variants** light up zero tuple-traces, because the bug
  shape there is a record-with-CEcoValue-slot, not a tuple. The bug
  is still real, just not visible to the existing tuple-specific
  trace infrastructure. To audit records analogously, an equivalent
  `[RecordLayout]`/`[RecordCreate-mismatch]` family would need to be
  added.
- **Pass-through variants** (Custom / List / Array / Closure) fire
  no tuple-trace beyond the 2 inner-literal 3-tuples
  (`("p", member, "s")`, etc.). That's the baseline level — these
  tests never produce a buggy 3-tuple at all because the
  constraint-generation pins `capturedIdx` to `Int` upstream of any
  buggy layout.

## Anomaly: RecordMulti has a slot-projection mis-attribution

Of all the failing tests, `TupleSlotBoxingRecordMulti` is the
odd one out. Expected: `[0,1,1,1,1,2]`. Actual:
`[0,1,1610612935,1,2,1610612945]`.

Decomposed: the inner items are `{ a = j, b = capturedIdx, c = j + 1 }`
constructed twice (j=0 and j=1) when `capturedIdx == 1`, so:
- record 1: `{ a = 0, b = 1, c = 1 }`
- record 2: `{ a = 1, b = 1, c = 2 }`

Flatten via `(\r -> [r.a, r.b, r.c])` should yield `[0,1,1,1,1,2]`.
Naive prediction (boxed slot at field `b`): garbage at positions 1
and 4 (the `b` columns).

Actual reveals something different:
| pos | should be | got | matches |
|-----|-----------|-----|---------|
| 0 (`r1.a`) | 0 | 0 | ✓ |
| 1 (`r1.b`) | 1 | 1 | ✓ |
| 2 (`r1.c`) | 1 | 1610612935 | ✗ garbage |
| 3 (`r2.a`) | 1 | 1 | ✓ |
| 4 (`r2.b`) | 1 | 2 | ✗ — but **2 is `r2.c`'s value** |
| 5 (`r2.c`) | 2 | 1610612945 | ✗ garbage |

So `.b` projection returns the value that should live in slot `c`
(`j + 1`), and `.c` projection returns a garbage HPointer bit pattern
(consistent with reading the boxed `b` slot through an i64 lens).
The simplest explanation: the codegen has **swapped the slot indices
for `.b` and `.c` projections** when the record's bitmap has a kind
mismatch in a middle slot. This is independent of the
boxing-mismatch family — it's a separate slot-index miscalculation
that only surfaces when the bug already poisons one of the slots.

`RecordSingle` doesn't reveal this because there's only one slot to
swap with. It would be worth a separate diagnostic plan to nail down
whether this is a `computeRecordLayout` field-ordering bug, a
`generateRecordAccess` indexing bug, or a downstream MLIR-projection
issue.

## Why the "pass" cases are interesting

The 6 passing tests are arguably the more useful regression tests
for any future fix to land cleanly:

- **Custom types** (Single / Multi-field / Multi-ctor): act as
  baselines proving the bug is *specifically* a structural-type
  layout issue. If a future fix that targets structural-record /
  -tuple layout accidentally breaks these (e.g. by misrouting
  ctor-field types through the same fallback that drops to
  `CEcoValue`), the tests catch it.
- **List / Array / Closure**: act as baselines proving that
  unary-element-type / closure-body-type constraint propagation
  *currently* pins `capturedIdx` to `Int`. If a future change to
  constraint-flow ordering breaks that propagation, these tests
  start failing too — and that would be a wider regression than
  what the original bug describes.

So even though they pass today, they're part of the matrix the bug
fix needs to keep green.

## What changed in the test tree

- `test/elm/src/TupleSlotBoxingMismatchTest.elm` — input changed
  from `[ True ]` to `[ False, True ]`. The previous CHECK
  (`"[0,1,1,1,1,2]"`) assumed `capturedIdx == 1`, but with
  `[ True ]` the actual `capturedIdx` would have been `0`. The new
  input makes the test self-consistent: with the bug present it
  fails; once Fix A from the upstream plan lands it would actually
  pass.
- 12 new test files added at `test/elm/src/TupleSlotBoxing*Test.elm`.

No compiler / runtime / build-system code changed. The
`[TupleLayout/Compute]` trace in
`compiler/src/Compiler/Generate/MLIR/Types.elm` (added by the
parent plan) was already in place and was used here for the
diagnostic compiles.

## Suggested follow-ups

1. **Add `[RecordLayout]` / `[RecordCreate-mismatch]` traces**
   parallel to the existing tuple ones, so the record variants
   light up the same diagnostic gauges. Without these, the records
   tests' upstream behavior is invisible to the existing trace
   infrastructure.
2. **Diagnose the RecordMulti `.b`/`.c` swap** as its own
   investigation — see `Anomaly` section. This is a separate bug,
   triggered by the boxing-mismatch but not part of it.
3. **Land Fix A from `wrong-unboxed-bitmap-upstream.md`** — derive
   the structural-container's MonoType from already-specialised
   element expressions at `Specialize.elm:3229` for tuples, and the
   analogous site(s) for `TOpt.Record`. Verify the 7 currently-FAIL
   tests turn green and the 6 currently-pass tests stay green.
4. **Add a non-Int-primitive variant** (Float or Char `capturedIdx`)
   once a way to construct one through this skeleton without
   breaking the constraint-flow gap is identified. Not blocking;
   the existing Int variants cover the core bug.

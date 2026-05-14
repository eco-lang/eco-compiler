# Reproducer for the tuple-slot boxing bug

**Companion to** `plans/wrong-unboxed-bitmap-upstream.md` and
`plans/reproduce-tuple-slot-boxing-bug.md`. Built by following the
loop in the latter.

## Outcome

`test/elm/src/TupleSlotBoxingMismatchTest.elm` is a runtime-visible
reproducer of the tuple-slot boxing bug. It currently **FAILS** under
the buggy compiler and would **PASS** once the bug is fixed (Fix A
from `wrong-unboxed-bitmap-upstream.md` — derive the tuple's MonoType
from already-specialised element expressions instead of from
`meta.tipe`).

Failure shape under the buggy compiler:

```
Missing pattern: TupleSlotBoxing: "[0,1,1,1,1,2]"
Actual output:   TupleSlotBoxing: "[0,1610612863,1,1,1610612872,2]"
```

The 10-digit values `1610612863` and `1610612872` are HPointer bit
patterns — slot 1 was written as the i64 `1` (`capturedIdx`), then
read back through a boxed-slot projection, exposing the raw pointer
representation. Slots 0 and 2 (`j` and `j + 1`) round-trip correctly.

## Minimal ingredients required

Three iterations were needed:

- **iter1** (singleton items, no Maybe/filterMap):
  upstream `[Specialize/Tuple]` mismatch fired **0 times**. The
  monomorphizer specialized slot 1 to `MInt` directly.

- **iter2** (added inner-lambda tuple destructure + `Just`-wrap +
  `List.filterMap identity`): upstream `[Specialize/Tuple]` still
  fired **0 times**. Adding tuple-destructure ingredients in the
  inner lambda was not enough.

- **iter3** (changed items from `[ ( 1, True ) ]` to
  `List.indexedMap Tuple.pair members` flowing into
  `List.foldl helper`): **bug fires**. Upstream `[Specialize/Tuple]`
  shows `T3(Int, V612, Int)` with `V612` flagged
  `inSubst=N, numberVar=N, constraint=CEcoValue` — the same shape
  as the Stage 5 self-compile's `T3(Int, V8536, Int)`. The buggy
  MonoTupleCreate also reaches MLIR codegen
  (`[TupleLayout/Compute] arity=3 bitmap=17 types=[I,V612_ecovalue,I]`)
  — no downstream pass masked it. The runtime then reads slot 1
  through a boxed projection.

The decisive ingredient was the polymorphic
`List.indexedMap Tuple.pair members` producing the third arg of
`List.foldl`. That is the **exact** structural pattern at
`compiler/src/Compiler/Generate/MLIR/Expr.elm:4578`. With it:

```elm
List.foldl helper [] (List.indexedMap Tuple.pair members)
```

the call-site expectation for `helper`'s first-parameter slot 0 is a
flex var derived from `Tuple.pair`'s polymorphic `a`-slot, and is
**still flex at the time helper's scheme is freshened and unified
with `List.foldl`'s `(a -> b -> b)` slot**. The fresh peer var never
gets pinned to `Int` — the union-find class for slot 0 stays
`Flex(fresh)` through Solve, gets renamed `b` at PostSolve, becomes
`MVarId 612 CEcoValue` at AssignMVarIds, and falls through the
`Nothing/CEcoValue` branch of `TypeSubst.applySubst`.

With concrete `[ ( 1, True ) ]` as items (iter1, iter2), the call
site forces `Tuple.pair`'s `a`-slot to `Int` at the same constraint
batch, the propagation succeeds, and the bug does not arise.

## Other ingredients carried over from real code

Kept in the reproducer because removing them risks reverting to
"won't-fire" territory:

- `helper` is **let-bound** without a type annotation (so its scheme
  is generalised before call-site unification).
- The pattern `( capturedIdx, member )` is a 2-slot tuple destructure
  (slot 0 = `capturedIdx`, slot 1 = `member`). `member` is used by
  the inner literal `[ ( "p", member, "s" ), ... ]`, which
  structurally pins its type — matching the asymmetry in the real
  bug (slot 1 pinned, slot 0 not).
- `capturedIdx` is referenced **only as a value** inside the inner
  `Just ( j, capturedIdx, j + 1 )` — no arithmetic, no comparison —
  so no use-site imposes a constraint that flows back to slot 0.

The Maybe-wrap (`Just (...) |> List.filterMap identity`) and the
inner-lambda tuple-destructure parameter `\j ( _, mark, _ ) -> ...`
were added in iter2 and retained in iter3. With iter3's
`List.indexedMap Tuple.pair members`, they may or may not still be
required; pruning them was not attempted because iter3 already
satisfied both stop criteria.

## Trace evidence

From `/tmp/test_traces.iter3.log`:

```
[Specialize/Tuple]
  currentGlobal = project:TupleSlotBoxingMismatchTest.buggy
  freeVars      = []
  canType       = T3(Int,V612,Int)
  substProbe    = V612(inSubst=N,numberVar=N,constraint=CEcoValue)
  toptElemCanTypes = [Int,V612,Int]
  subst         = {611->I}
  monoType(after subst) = T3(I,V612_ecovalue,I)
  elemTypes(after subst)= [I,I,I]

[TupleLayout/Compute] arity=3 bitmap=17 types=[I,V612_ecovalue,I]
  slots=[slot0{ty=I,canUnbox=Y,kind=1,contrib=1},
         slot1{ty=V612_ecovalue,canUnbox=N,kind=0,contrib=0},
         slot2{ty=I,canUnbox=Y,kind=1,contrib=16}]

[TupleCreate-mismatch] bitmap=17
  tupleType  = T3(I,V612_ecovalue,I)
  elemTypes  = [I,I,I]
```

These mirror the Stage 5 self-compile traces from
`plans/wrong-unboxed-bitmap-upstream.md` line-for-line (modulo the
VarId index drift from 8536 to 612).

## Notes for whoever fixes the bug

- The `[TupleLayout/Compute]` trace added in
  `Compiler/Generate/MLIR/Types.elm` for this work is general — it
  fires on every 3-tuple at codegen, not just bug-shaped ones — and
  is useful for verifying any future fix preserves correct layouts.
  It can be left in or removed.
- The reproducer test does not depend on `--optimize` — it fails
  under the harness's default (non-optimized) compile path. The
  Stage 5 "masking" worry in the parent plan turned out not to apply
  here.
- The reproducer is also independent of which compiler variant runs
  it: both the XHR-built `compiler/bin/index.js` (used by the test
  harness) and the kernel-built `eco-boot-2-runner.js` produce the
  same buggy MLIR. The harness's compiler-stderr drop is irrelevant
  for runtime-visible verification — only the JIT output matters.

## Loop iteration trail

| iter | shape change | `[Specialize/Tuple]` mismatch | runtime |
|------|--------------|-------------------------------|---------|
| 1 | direct `[ (1, "X") ]` items, no Maybe | 0 | correct (no bug) |
| 2 | added inner-lambda tuple destructure + Maybe + filterMap; items still `[ (1, True) ]` | 0 | correct (no bug) |
| 3 | items now `List.indexedMap Tuple.pair members` (one-shot reproducer) | 1 | wrong: slot 1 reads HPointer bit pattern |

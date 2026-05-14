# Reproduce the tuple-slot boxing bug in an E2E test

**Scope:** create a small E2E test under `/work/test/elm/src/` that
reproduces the bug from `plans/wrong-unboxed-bitmap.md` /
`plans/wrong-unboxed-bitmap-upstream.md` — a tuple slot that was
written as an unboxed `Int` (with value `1`) but read back as a heap
address (typically a 9–10 digit garbage integer). Iterate by
trace-diffing against the self-compile until the test fires the same
shape.

**Out of scope:** any compiler fix. This plan is for **regression
demonstration**, not remediation.

## Loop in one paragraph

> Write a candidate Elm test in `test/elm/src/`. Build it through the
> E2E test harness. If the runtime output shows the wrong slot
> reading back as `1` (or any small int), the bug didn't fire —
> proceed to diff diagnostic traces between the test compilation and
> the self-compile; identify the *first* structural ingredient that
> diverges; add it to the test; loop. If the runtime shows a large
> garbage integer (an HPointer bit pattern) where `1` was written,
> stop — that's a successful reproducer.

## Background carried over from prior work

The upstream conditions are already characterised in
`plans/wrong-unboxed-bitmap-upstream.md`:

- Bug site in real code: `compiler/src/Compiler/Generate/MLIR/Expr.elm:4451`,
  `buildSiblingData ( consumerIdx, member ) acc = ...`, used in a
  `List.foldl buildSiblingData ... (List.indexedMap Tuple.pair members)`
  pattern.
- Smoking gun at Specialize:
  `canType = T3(Int, V8536, Int) → monoType = T3(I, V8536_ecovalue, I)`
  while `elemTypes = [I, I, I]`.
- Upstream cause: the constraint that should unify the slot-0 flex
  var (e.g. `Pt6806`) with `Int` is never generated; the UF class
  stays `Flex(fresh)` through Solve and is fresh-named `b` at
  PostSolve.
- Surprise: at Stage 5 self-compile, the buggy `MonoTupleCreate` is
  caught at Specialize but **does not survive to MLIR codegen** (some
  intermediate pass between Specialize and codegen rewrites the
  MonoType). The runtime symptom only surfaced at Stage 7b in the
  original report. So the test program may need to defeat whatever
  Stage-5 masking exists, or the runtime symptom may only fire under
  certain compilation paths.

Traces are already wired in (under `Eco.Console.log`) in:

- `Specialize.elm` — `[Specialize/Tuple]` (mismatch only),
  `[Specialize/Tuple/Always]` (every 3-tuple), `[Specialize/Tuple/SubstProbe]`.
- `Types.elm` — `[TupleLayout]` (any tuple containing
  `MVar _ CEcoValue` — widened, fires on the *raw* buggy shape if it
  reaches codegen).
- `Expr.elm` — `[TupleCreate-mismatch]` (any slot mismatch between
  layout decision and `Mono.typeOf elemExpr`).
- `AssignMVarIds.elm` — `[AssignMVarIds/...]` per ID window.
- `Type.elm` — `[PostSolve/Resolve]` per FlexVar→Can.TVar.
- `Unify.elm` — `[Solve/Unify-merge]` on fresh-flex-involving merges.
- `Constrain/Typed/Pattern.elm` — `[Constrain/Pattern/Tuple]` per
  tuple-pattern slot, with source region.

These will be extended in **Step 0b** (below) with a finer-grained
`computeTupleLayout` instrumentation to log *every* invocation, not
just the suspicious-shape one.

## Loop step-by-step

### Step 0 — Test harness orientation

Read `/work/test/CMakeLists.txt`, `/work/test/ElmE2ETestBase.hpp`,
`/work/test/elm/ElmTest.hpp`, plus the existing CMake bootstrap-stage
targets, to answer:

- Where does the harness invoke the compiler to produce `.mlir` from
  test `.elm` sources? Is it via the already-built `eco-compiler`
  (native) or via `node bin/eco-boot-2-runner.js`?
- Where does **compiler stderr** for each test go? Specifically — is
  it captured per-test, piped to a log file, sent to `/dev/null`, or
  surfaced through `IsolatedTestRunner.hpp`?
- How does `TEST_FILTER=TupleSlotBoxing cmake --build build --target
  full` map to one test invocation? Does `--target full` always
  rebuild the bootstrap-stage compiler (Stages 1–5), or only when
  compiler source changed?
- What is the `-- CHECK:` matching semantics — exact-line,
  substring, or regex? Read 2–3 sample tests (`AddTest.elm`,
  `ListFoldlTest.elm`, `AnonymousFunctionTest.elm`) **and** the
  matcher implementation.

Concrete plan for the stderr-capture question (the harder one):

1. Grep for `2>` redirections, `stderr` mentions, and
   `popen`/`stderr_to` in `test/*.hpp` and `runtime/.../EcoRunner.hpp`.
2. Run one existing test under `strace -f -e openat`-ish observation
   *or* set `ECO_CONSOLE_LOG=1`-style guard in `Eco.Console.log`
   (already always-on, so guarding isn't necessary) and check whether
   the test output includes any `[...]` trace lines.
3. If stderr is dropped per-test, plan a **manual outer-loop**: run
   the test compilation step by hand (`node bin/eco-boot-2-runner.js
   make ... TupleSlotBoxingMismatchTest.elm 2>/tmp/test_traces.log`)
   for the diagnostic stream, and let `--target full` separately do
   pass/fail verification.

Deliverable: a short note (committed alongside the test, or as a
section appended to this plan when done) describing how stderr is
captured and which command sequence the loop will use. **No test
code yet.**

### Step 0b — Add a granular `[TupleLayout/Compute]` trace

The existing `[TupleLayout]` trace fires only when the input type
list contains an `MVar _ CEcoValue`. That's useful for *finding* the
bug shape, but not for *understanding why a particular layout came
out wrong*. Per the user's direction, add a finer trace inside
`computeTupleLayout` (`Compiler/Generate/MLIR/Types.elm:557`) that
fires on **every** call (or every 3-tuple call, to bound volume),
and reports:

- The full input `types` list as `prettyMonoTypeTrace`.
- For each slot: `canUnbox` result, `encodeUnboxedKind` result, the
  contribution to the bitmap (`kind << (2 * idx)`).
- The final `unboxedBitmap`.
- The current `currentGlobal` if reachable (it isn't from `Types.elm`
  directly — may need to thread a context string from the caller).

Tag: `[TupleLayout/Compute]`. Gate: `arity == 3` to bound volume.

Purpose: when we get to Q3 in the diagnostic diff, we want to be
able to ask "why did this specific call produce bitmap N?" without
re-instrumenting. A per-slot kind breakdown answers that directly.

A symmetric trace at the consumer side (`generateTupleCreate`,
`Expr.elm:5661`) already exists as `[TupleCreate-mismatch]`. Consider
also widening it to `[TupleCreate-always]` (or gating only on
`arity == 3`) for the same reason — every 3-tuple's construction
should be visible during diagnostic iterations.

### Step 1 — Write the initial candidate test

File: `test/elm/src/TupleSlotBoxingMismatchTest.elm`. Start minimal
— the same shape vetted in the prior conversation. **Crucially, use
`Eco.Console.log` (not `Debug.log`)** since the compiler may be run
under `--optimize` which rejects `Debug.*`:

```elm
module TupleSlotBoxingMismatchTest exposing (main)

-- CHECK: TupleSlotBoxing: [0,1,1,1,1,2]

import Eco.Console
import Html


buggy items =
    let
        helper ( capturedIdx, _ ) acc =
            let
                triples =
                    List.indexedMap
                        (\j _ -> ( j, capturedIdx, j + 1 ))
                        [ "a", "b" ]
            in
            triples ++ acc
    in
    List.foldl helper [] items


flatten triples =
    List.concatMap (\( p, c, s ) -> [ p, c, s ]) triples


main =
    let
        result =
            buggy [ ( 1, "X" ) ] |> flatten

        _ =
            Eco.Console.log
                ("TupleSlotBoxing: " ++ stringOfIntList result)
                ()
    in
    Html.text "done"


stringOfIntList xs =
    "["
        ++ (xs |> List.map String.fromInt |> String.join ",")
        ++ "]"
```

Design decisions, anchored to the upstream cause:

- `helper` is let-bound and unannotated, mirrors `buildSiblingData`.
- First param `( capturedIdx, _ )` is a tuple destructure → mints two
  flex vars at `addTupleWithIdsProg`.
- `capturedIdx` is used only as data inside an inner closure, no
  arithmetic or comparison on it.
- Inner lambda is the callback to a polymorphic HOF
  (`List.indexedMap : (Int -> a -> b) -> List a -> List b`), with the
  captured value in slot 1 of a 3-tuple.
- Slots 0 (`j`) and 2 (`j + 1`) are forced to `Int`.
- `flatten` destructures `( p, c, s )` and reads all three slots as
  `Int`, surfacing any boxing/unboxing mismatch at slot 1.
- Input `[ ( 1, "X" ) ]` so the expected slot-1 value is `1` —
  deliberately small so a heap-pointer bit pattern stands out as
  clearly wrong.
- The runtime output is rendered via `stringOfIntList result` so the
  CHECK line can be matched as a single literal string, regardless
  of how the harness's matcher compares lines.

Build and run the test once via the harness; also capture compiler
stderr to a temp file (via the strategy chosen in Step 0).

### Step 2 — Decision branch on the first run

Two outcomes:

**(A) Bug reproduces.** Runtime output shows
`TupleSlotBoxing: [0,<huge>,1,1,<huge>,2]` instead of
`[0,1,1,1,1,2]`. The `-- CHECK:` line fails to match. **STOP — the
test is the reproducer. Commit, write a brief report, exit the
loop.**

**(B) Bug doesn't reproduce.** Runtime output matches expected (small
ints in slot 1). The test ran successfully; we have NOT yet
reproduced the bug. Go to Step 3 (diagnostic diff).

### Step 3 — Diagnostic diff: where does the test diverge from the self-compile?

Capture two diagnostic-trace streams:

1. **Test-trace:** invoke the test compilation directly (so we keep
   stderr):

       cd /work/compiler/build-kernel
       find eco-stuff -name "*.ecot" -delete
       node --stack-size=65536 bin/eco-boot-2-runner.js make --optimize \
           --kernel-package eco/compiler \
           --local-package eco/kernel=/work/eco-kernel-cpp \
           --output=/tmp/testcase.mlir \
           /work/test/elm/src/TupleSlotBoxingMismatchTest.elm \
           2>/tmp/test_traces.log

2. **Self-compile-trace** — already on disk as
   `/tmp/stage5_traces5.log` from the prior plan. If stale, rerun
   the same way against `compiler/src/Terminal/Main.elm`.

Then ask three diagnostic questions in order, looking at the test-
trace first then comparing to the self-compile-trace:

#### Q1 — Did `[Specialize/Tuple]` fire on the test?

    grep -c "^\[Specialize/Tuple\]" /tmp/test_traces.log

- **If yes (≥1)**: the *upstream* bug shape is present in the test
  compilation. The MonoTupleCreate has the buggy `MVar _ CEcoValue`
  in slot 1. The reason the runtime symptom didn't surface is
  downstream masking — skip to Q3.

- **If no (0)**: the upstream bug shape is **not** present. The test
  is missing some structural ingredient that pushes constraint flow
  toward unbinding slot 0. Go to Q2.

#### Q2 — Which structural ingredient is missing?

This is the "look at the structure of real code and bring in
variations" step. The structural template to draw variations from is
**not just `buildSiblingData` itself** but its surrounding context.
We have to look at the **journey** the type variable takes — who
calls `generateExpr`, what closure depth `buildSiblingData` lives
inside, what `members` actually is, what types pass through
neighbouring expressions, etc.

Per-iteration approach:

1. **Read the surrounding 50–200 lines** at
   `compiler/src/Compiler/Generate/MLIR/Expr.elm:4400-4600` to
   understand the *context* `buildSiblingData` lives in (which
   variables are captured, which records are accessed, what's the
   surrounding `case`/`let` structure).
2. **Find the call sites of `generateExpr`** — `grep -rn
   "generateExpr " compiler/src/Compiler/Generate/MLIR/` — and look
   at the closure/lambda nesting depth at each. Are there
   `Compiler.Generate.MLIR.Functions.generateFunction` /
   `Compiler.Generate.MLIR.Lambdas.generateLambda` wrappers that
   introduce additional scheme freshening before `generateExpr` is
   reached?
3. **Read the trace's `[AssignMVarIds/...]` entries** around V8536:
   the IDs immediately preceding it (V8530–V8535) tell us which
   *named* schemes were instantiated just before the bug-producing
   path. If we see e.g. lots of `name=a` and `name=b` allocations
   for unrelated schemes, those are the polymorphic HOF
   instantiations whose constraint chains feed into V8536's UF
   class.

Candidate variations, ordered cheapest-first, with the structural
reasoning each one targets:

(i) **Bigger outer list.** `[ ( 1, "X" ), ( 2, "Y" ) ]` vs a
   singleton. Real `members` is non-trivial; let-poly call-site
   instantiation may need >1 fold step or >1 list element to push
   constraints into the failure ordering.

(ii) **Multiple call sites for the helper.** Reference `helper` in
    two different `List.foldl` calls within the same module. Many
    let-polymorphic bugs require ≥2 instantiation sites.

(iii) **Non-trivial second slot.** Replace `String` with a small
     record `{ name : String, idx : Int }`. The real `member`
     value is a record with several fields. A record type's
     constraints may force a different freshening order than
     `String`.

(iv) **Inner lambda destructures a tuple in its parameter.** Real
    code: `\j ( _, captureExpr, _ ) -> ...`. The inner lambda's
    parameter pattern itself is a tuple destructure → another
    `addTupleWithIdsProg` invocation that could be the trigger.

(v) **Maybe-wrap + filterMap identity.** Real code emits
   `Just ( producerIdx, consumerIdx, slot )` from the inner lambda
   and `|> List.filterMap identity` outside. The `Maybe` is
   polymorphic, adding a freshening layer.

(vi) **Dict.get + Maybe pattern match.** Real code does
    `case Dict.get refName memberIndex of Just producerIdx -> ... Nothing -> ...`
    inside the inner lambda. Adds another set of polymorphic chains
    (Dict is polymorphic in key, value).

(vii) **Surrounding closure.** The buggy 3-tuple is inside a `let`
     block inside a `let` block inside `generateExpr`. Try wrapping
     the test's outer fn in a closure that captures a free variable
     from `main` — `\unused -> buggy items`.

(viii) **Top-level binding.** Move `buggy` to a top-level definition
      with its own scheme, instead of inline-in-`main`. Real
      `generateExpr` is a top-level scheme.

(ix) **Module-level structural complexity.** Real `Expr.elm` has
    hundreds of co-located top-level functions, many of which are
    co-recursive. The test could add a few extra co-located helpers
    with unrelated polymorphic chains to perturb the typecheck.

Pick the *cheapest* variation that the trace-diff suggests as
relevant. For example, if the test's `[Constrain/Pattern/Tuple]`
appears only once but the real code shows several adjacent tuple
patterns at the same call depth, try (iv) first.

#### Q3 — Why is the runtime symptom not firing when upstream IS firing?

The `[Specialize/Tuple]` trace fires, so the buggy
`MonoTupleCreate` exists. Either it gets rewritten downstream in
MLIR codegen, or it gets compiled correctly anyway (perhaps the
inner expressions' SSA types compensate). Use the new
`[TupleLayout/Compute]` trace from Step 0b to drill in.

Compare the trace fingerprints at three downstream checkpoints:

(a) `[TupleLayout/Compute]`: does it fire on the buggy MonoTupleCreate's
   element-types? If we see `[TupleLayout/Compute] arity=3 types=
   [I, V_<id>_ecovalue, I]`, the MVar reached codegen and the
   bitmap should be wrong. If instead we see
   `[TupleLayout/Compute] arity=3 types=[I, I, I]`, then **the
   MonoType was rewritten between Specialize and codegen** — that's
   the masking we have to defeat. The new per-slot trace from Step
   0b will also show the `canUnbox` decision per slot, so the
   bitmap-build chain is fully visible.

(b) `[TupleCreate-mismatch]`: does it fire with a non-21 bitmap and
   a tupleType containing `_ecovalue`? Tells us whether codegen
   emitted the wrong bitmap.

(c) Did `eco.construct.tuple3` actually get emitted in the test's
   MLIR? Check `/tmp/testcase.mlir` for `tuple3` ops. The bug
   requires a literal 3-tuple construction. If MLIR doesn't contain
   `tuple3`, something in the optimisation chain has flattened or
   inlined the test away.

Counter-responses:

- **`[TupleLayout/Compute]` fires with the buggy element list +
  `[TupleCreate-mismatch]` fires** but the runtime is still
  "correct": the runtime is reading the slot in a way that
  auto-boxes/unboxes through generic-apply. Make the read more
  direct (avoid `Eco.Console.log` on the result; fold across it
  and assert each `c == 1` programmatically; use
  `String.fromInt c` per element).

- **`[TupleLayout/Compute]` fires with `[I, I, I]`** but
  `[Specialize/Tuple]` reported `_ecovalue` upstream: confirmed
  Stage-5 masking. Defeat by:
  - Adding more references to the tuple-producing helper so it
    doesn't get inlined.
  - Making the consumer/producer chain less amenable to constant-
    folding (pass `items` from `Html.flags`, or `Eco.Console.log`-wrap
    an intermediate value so the optimiser can't prove the result
    is dead).
  - `identity`-wrapping intermediate computations.
  - Disabling `--optimize`. Yes — the simplest "defeat-the-mask"
    move is to compile the test *without* `--optimize`, which
    typically disables `MonoInlineSimplify` /
    `MonoGlobalOptimize`. The test will still be a valid runtime
    reproducer, just not under optimisation. The harness may or may
    not let us toggle this; need to check.

- **`[Specialize/Tuple]` fires but `[TupleLayout/Compute]` doesn't
  fire at all** (no `arity=3` calls): the entire 3-tuple was
  collapsed before codegen, e.g. inlined as constants. Same defeat
  options as above.

### Step 4 — Edit, rebuild, rerun

For each variation chosen in Step 3:

1. Edit `TupleSlotBoxingMismatchTest.elm`.
2. Rerun the manual diagnostic compile (Step 3's command), capturing
   `/tmp/test_traces.log`.
3. **Also** rerun the harness if applicable:
   `TEST_FILTER=TupleSlotBoxing cmake --build build --target full`.
4. Diff the new test trace against the prior iteration's trace
   (using `[Specialize/Tuple/SubstProbe]`, `[AssignMVarIds/...]`,
   `[TupleLayout/Compute]`).
5. Inspect the runtime output. Re-evaluate Step 2's branch.

Move `/tmp/test_traces.log` → `/tmp/test_traces.iter{N}.log` between
iterations to keep a chain of evidence.

### Step 5 — Stop criteria (success)

A test is a **successful reproducer** when **both**:

- The runtime output shows the middle slot of at least one tuple
  reading back as a value that is clearly not `1` (a wide-range
  integer; anything more than ~5 digits is a strong signal it's an
  HPointer).
- The test's `-- CHECK:` line matches the *correct* expected output
  (so the harness reports FAIL on the buggy compiler and would
  report PASS once the bug is fixed).

Save the test, write a brief
(`plans/tuple-slot-boxing-reproducer.md`) summarising what
combination of ingredients reproduces it, and STOP.

### Step 6 — Stop criteria (give-up)

Hard cap: **8 iterations** before bailing.

- If upstream `[Specialize/Tuple]` fires but runtime symptom never
  does (Q3 territory persistently): commit the test as
  `TupleSlotBoxingUpstreamTest.elm` and assert against trace output
  rather than runtime. Still useful as upstream-regression.
- If upstream `[Specialize/Tuple]` never fires (Q2 territory
  persistently): record what was tried in
  `plans/tuple-slot-boxing-reproducer.md` and move on.

## Trace-gating strategy

Per the user's feedback: enable/disable traces as appropriate to the
task at hand; gate by variable name/id once known.

**Default iteration profile (low volume):**

- Keep on: `[Specialize/Tuple]`, `[Specialize/Tuple/Always]`,
  `[Specialize/Tuple/SubstProbe]`, `[Constrain/Pattern/Tuple]`,
  `[AssignMVarIds/...]`, `[TupleLayout/Compute]` (new from Step 0b),
  `[TupleCreate-mismatch]`.
- Disable (comment out) during iteration:
  `[Solve/Unify-merge]` (was 99% of volume),
  `[PostSolve/Resolve]` (also large).
- Re-enable Solve/PostSolve only **after** Q1/Q2 has narrowed the
  suspect to a specific name / Pt-index, then re-instrument with a
  gate like:
  - `Solve/Unify-merge` only when one side's content is
    `Flex(<name>)` or `FlexSuper(<name>)` for the names of interest;
  - `PostSolve/Resolve` only when var Pt-index is in a narrow window
    or name matches.
- For sharper gating once an offending Pt-index is identified,
  add per-iteration `if Id.toComparable id == 8536 then ... else
  ...` (or the equivalent on `Variable`).

## What the loop reads from the diagnostic infrastructure

- `[Specialize/Tuple]` (mismatch case) — primary upstream signal.
  Fires once per offending 3-tuple. Compare counts and contents
  between test and self-compile.
- `[Specialize/Tuple/Always]` — secondary signal showing every
  3-tuple's `monoType0 vs elemDerivedType`. Useful to see whether
  the test produces 3-tuples *at all* in the specialiser.
- `[Specialize/Tuple/SubstProbe]` — for any offending 3-tuple,
  shows which TVar IDs are in / not in `subst`, with constraints.
  Smoking-gun for "this V_N is the unbound one".
- `[Constrain/Pattern/Tuple]` — fires per source region. Used to
  count tuple-patterns in test vs near `Expr.elm:4451`.
- `[AssignMVarIds/freshMVarId]` + `ensureMVarId` — for the
  offending TVar's name, confirms the alloc path (source=ensureMVarId
  vs ensureMVarIdForRoot). Useful to confirm the test's V is
  allocated the same way as self-compile's V8536.
- `[TupleLayout/Compute]` (new) — per-call breakdown of the
  layout decision for every 3-tuple at codegen. Distinguishes
  "MVar reached codegen" from "MVar was masked".
- `[TupleCreate-mismatch]` — per-call mismatch between layout
  decision and SSA element type.

## Open questions / assumptions

1. **Where does the harness send compiler stderr per-test?** Unknown
   — to be resolved in Step 0. If dropped, the loop uses a manual
   compile-then-verify split (manual compile for traces; harness for
   pass/fail). If captured to a per-test log file, even better.

2. **`-- CHECK:` matching semantics** — exact-line, regex, or
   substring? To be confirmed in Step 0 by reading 2–3 sample tests
   and the matcher. Affects whether the test asserts the literal
   `[0,1,1,1,1,2]` or a fragment. (Step 1's test uses the
   safe-for-any-matcher form: render the list with a string helper,
   match on the rendered literal.)

3. **Can the harness compile the test under `--optimize=false`?**
   If yes, that's the cheapest "defeat-the-masking" move in Q3.
   Need to check whether `cmake --build build --target full`
   exposes the optimisation flag per-test.

4. **Risk that Stage-5 masking holds for the test too.** Plausible.
   That's why Step 6 accepts an upstream-only reproducer as a
   partial success.

5. **One-tuple-only vs many-tuple cardinality.** Default to a
   singleton input in Step 1 for minimality; if Q2 fires, variation
   (i) is the very first thing to try.

6. **Source-file layout / line numbers** — irrelevant; the trace
   gates on type-shape conditions, not on source regions.

## Deliverable

`test/elm/src/TupleSlotBoxingMismatchTest.elm` that fails the runtime
assertion on the current (buggy) compiler and would pass once the
bug is fixed, plus a brief `plans/tuple-slot-boxing-reproducer.md`
recording the iteration trail and the minimal set of structural
ingredients required.

(Or, if Step 6 fires: `TupleSlotBoxingUpstreamTest.elm` that asserts
against the trace output rather than runtime, with documentation of
why we couldn't get a runtime-visible reproducer.)

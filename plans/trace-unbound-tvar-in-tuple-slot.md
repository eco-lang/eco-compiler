# Trace the origin of the unbound TVar in the tuple-slot boxing bug

**Scope: diagnostics only.** No fixes (no Fix A at `Specialize.elm:3229`, no
record-side mirror, no PostSolve/Solve changes). The deliverable is a
chronologically ordered trace report that pins down which phase first
created the offending TVar and which phase failed to bind it.

## Goal

Re-introduce the three "downstream" trace points that produced the
`wrong-unboxed-bitmap.md` report, then add **upstream** trace points
working backwards from `Specialize.elm:3209` (`TOpt.Tuple` case) into:

1. `Compiler.Monomorphize.Specialize` setup (which TVars are in `subst`,
   which aren't),
2. `Compiler.Monomorphize.AssignMVarIds` (where the offending MVarId is
   born and from which kind of source),
3. `Compiler.Type.PostSolve` (whether PostSolve saw the still-`Flex`
   root and chose not to default it),
4. `Compiler.Type.Solve` / `Compiler.Type.Unify` (whether the solver
   ever received a constraint that should have unified the root with
   `Int`),
5. `Compiler.Type.Constrain.Typed.Pattern.addTupleWithIdsProg`
   (`Pattern.elm:556`, where the fresh flex var per tuple-pattern slot is
   first introduced), and the corresponding expression-side constraint
   site for `VarLocal "capturedIdx"`.

The plan ends with a written-up trace report that answers:

- Which line of which phase first created the TVar that ends up as
  `V8531`?
- At which phase boundary did it cease to be linkable to `Int`?
- Whose responsibility was it to resolve it: Solve, PostSolve, or
  Monomorphize?

## Logging mechanism

All trace points use `Eco.Console.log : String -> a -> a`
(`eco-kernel-cpp/src/Eco/Console.elm:77`, kernel-backed by
`_Console_log` in `eco-boot*.js`). It writes `tag\n` to stderr and
returns its `a` argument unchanged, so it can be sprinkled into pure
expressions:

```elm
monoType =
    Eco.Console.log "[Specialize/Tuple] ..." <|
        Mono.forceCNumberToInt (applySubstFV state subst canType)
```

All guards are evaluated *before* the log string is constructed, so
untrue cases pay no string-construction cost:

```elm
monoType0 =
    Mono.forceCNumberToInt (applySubstFV state subst canType)

monoType =
    if shouldTrace monoType0 allExprs then
        Eco.Console.log (buildTag ...) monoType0
    else
        monoType0
```

Tag prefixes (so we can grep the stderr capture later):

- `[TupleLayout]`
- `[TupleCreate-17]`
- `[Specialize/Tuple]`
- `[Specialize/Tuple/SubstProbe]`
- `[AssignMVarIds]`
- `[PostSolve]`
- `[Solve/Unify]`
- `[Constrain/Pattern/Tuple]`
- `[Constrain/Expr/VarLocal]`

## Background (recap from `wrong-unboxed-bitmap.md`)

- `Specialize.elm:3209` (`TOpt.Tuple` case) computes
  `monoType = Mono.forceCNumberToInt (applySubstFV state subst canType)`
  where `canType = meta.tipe = Tup(Int, TVar V8531, Int)`.
- `subst` (size 11, IDs 8495–8505) does **not** contain `8531`.
- `state.ctx.mvarEnv.numberVars` does not contain `8531`.
- In `TypeSubst.applySubst` (line 625–635) the `Nothing` branch fires,
  reads `constraintOf 8531 env = CEcoValue`, and returns
  `Mono.MVar 8531 CEcoValue` for slot 1.
- The element expression at slot 1 is `MInt` at SSA level, so
  `monoType` and `Mono.typeOf` of the elements disagree.
- `computeTupleLayout` consumes the (wrong) `monoType`, sets bitmap = 17,
  and a downstream boxing/unboxing mismatch surfaces at runtime as
  "HPointer read as i64".
- The previous trace also established that `V8531` is **not** a scheme
  free var: `currentScheme = generateExpr`, `freeVars = []`. So
  `V8531` is an internal TVar that lives inside `generateExpr`'s body
  and was never linked to a concrete type by the solver.

## Step-by-step plan

### Step 1 — Restore the three downstream trace points

All guarded with cheap predicates. Sink: `Eco.Console.log`.

**(a) `Compiler.Generate.MLIR.Types.computeTupleLayout` (Types.elm:557).**
Guard: arity == 3 AND bitmap not in `{ 0, 21 }`. Log:

    [TupleLayout] arity=3 bitmap=<N> types=[<pretty Mono.typeOf>...]

**(b) `Compiler.Generate.MLIR.Expr.generateTupleCreate` (Expr.elm:5661).**
Guard: `layout.unboxedBitmap == 17`. Log:

    [TupleCreate-17]
      tupleType  = <pretty tupleType>
      elemTypes  = [<typeOf each element>]

**(c) `Compiler.Monomorphize.Specialize.specializeExpr` `TOpt.Tuple`
case (Specialize.elm:3209).**
Guard: `Mono.MTuple (List.map Mono.typeOf allExprs) /= monoType` AND
length == 3. Log:

    [Specialize/Tuple]
      currentScheme = <state.ctx.currentScheme>
      freeVars      = <state.ctx.currentFreeVars>
      canType       = <pretty canType>
      diag          = <ad-hoc pretty: per-slot (inSubst?, isNumberVar?, constraint)>
      toptElemCanTypes = [<TOpt.typeOf a, b, rest>]
      subst         = <pretty (Dict.toList subst)>
      monoType(after subst) = <pretty monoType>
      elemTypes(after subst)= [<typeOf monoA, monoB, monoRest>]

After this step, run the **Stage 5** build that produces
`eco-compiler.mlir` (see Step 7), redirect stderr to a temp file, and
verify the captured trace reproduces the lines quoted in
`wrong-unboxed-bitmap.md`. If it doesn't match, the bug has moved /
been masked; the plan continues against the new trace.

### Step 2 — Subst-probe at the same TOpt.Tuple site

Add a fourth trace point at `TOpt.Tuple` (`Specialize.elm:3209`),
above the existing one, that walks `Can.freeVars canType` and for each
`Can.TVar mvarId` logs:

    [Specialize/Tuple/SubstProbe]
      mvarId       = <id>
      inSubst      = <Dict.member key subst>
      inNumberVars = <Set.member id state.ctx.mvarEnv.numberVars>
      constraint   = <constraintOf id state.ctx.mvarEnv>
      rootInfo     = <if solver-root-backed, root descriptor; else "named:<name>" or "fresh">

`rootInfo` is the bridge to PostSolve / Solve: if the MVarId was
assigned through `ensureMVarIdForRoot` (`AssignMVarIds.elm:184`), the
trace records the `IO.Variable` solver root so we can correlate with
later Solve/PostSolve traces.

Expected output for the buggy case (matches what the previous trace
report stated):

    [Specialize/Tuple/SubstProbe] mvarId=8531 inSubst=False
      inNumberVars=False constraint=CEcoValue rootInfo=<TBD>

### Step 3 — Trace MVarId allocation in `AssignMVarIds`

Add trace points at `AssignMVarIds.freshMVarId` (`AssignMVarIds.elm:124`),
`ensureMVarId` (`:159`), and `ensureMVarIdForRoot` (`:184`). To keep
volume tolerable, **gate by id window**:

```elm
shouldTraceId : MVarId -> Bool
shouldTraceId id = id >= 8500 && id <= 8600
```

Format:

    [AssignMVarIds/freshMVarId] id=<id> constraint=<C> source=<calling fn> name=<canon name|->
    [AssignMVarIds/ensureMVarId] id=<id> name=<n> reused=<bool>
    [AssignMVarIds/ensureMVarIdForRoot] id=<id> root=<IO.Variable> name=<n>

This identifies *where* `V8531` is born:

- `source = ensureMVarId` → it's a *named* TVar from some scheme
  signature.
- `source = ensureMVarIdForRoot` → it's a *solver-root-backed*
  variable; we get the `IO.Variable` and can ask the solver descriptor
  what (if anything) the root was unified with.
- `source = freshMVarId` direct → it's a filler (`freshMVar
  Mono.CEcoValue` from `Specialize.elm:540`/`561`/etc.).

The structural pattern in the report (inner lambda of
`List.indexedMap`) strongly suggests `ensureMVarIdForRoot`, but the
trace will say definitively.

### Step 4 — Trace `Type.PostSolve` handling of that root

Once Step 3 names the variable / root, add a trace point in
`Compiler.Type.PostSolve.postSolve` (`PostSolve.elm:59`) — at module
entry plus inside each path that resolves a `Can.TVar`:

    [PostSolve/Resolve] node=<NodeId> tvar=<name> rootContent=<Flex|Rigid|Structure ...>

Gate by `tvar` matching one of the names Step 3 surfaces. Expected
outcome for the buggy case: the root is still `Flex` (unbound) at
PostSolve time → the solver never unified it with `Int`.

If `PostSolve` has any pass that **could** have substituted a default
type for `Flex` roots, instrument that decision point too:

    [PostSolve/Default] tvar=<name> beforeContent=<Flex> chosen=<...|skipped reason=<...>>

This is the data point that says whether PostSolve owns the fix or
defers to Monomorphize.

### Step 5 — Trace `Type.Solve` / `Type.Unify` involving that root

This is the deepest upstream step. Instrument the descriptor-update
path in `Compiler.Type.Solve` / `Compiler.Type.Unify`. Gating
strategy:

- First pass: gate by **type-variable name**. The
  `Compiler.Type.Constrain.Typed.Pattern` site introduces flex vars
  with auto-generated names (likely numbered, e.g. `_a1`, `_b2`); the
  expression-side site for `VarLocal "capturedIdx"` uses the binding's
  name. Pick the most distinctive name in the relevant area
  (`buildSiblingData`, `crossEdgesForSibling`, or
  `Compiler.Generate.MLIR.Expr.generateExpr`) and filter Solve trace
  by it.

- Second pass: once Step 3's `[AssignMVarIds/ensureMVarIdForRoot]`
  output tells us the `IO.Variable` identity backing `V8531`,
  re-gate on **that root's `IO.Variable`** for surgical precision.
  (Solve runs before AssignMVarIds, so the first pass must use names;
  the second pass can be re-run with the now-known root identity if
  needed.)

Format:

    [Solve/Unify] step=<n> left=<varOrType> right=<varOrType> newContent=<...> via=<call site>

The goal is a binary answer: **did the solver ever receive a
constraint that should have unified this root with `Int`, and if so,
why did the unification not stick?** Two scenarios we want to
distinguish:

- **(A) Constraint never generated.** The pattern `(capturedIdx, _)`
  introduces a flex var (via `addTupleWithIdsProg`,
  `Pattern.elm:556`), but no later expression imposes `Int` on the
  captured-into-tuple-slot position. → constraint-generation gap.
- **(B) Constraint generated but propagated through
  `List.indexedMap`'s scheme freshening such that the inner-lambda
  `b`'s flex var becomes a *different* root from the tuple-slot flex
  var.** → freshening/instantiation soundness gap.

### Step 6 — Trace `Constrain/Typed/Pattern` and `Constrain/Typed/Expression`

**(a) `addTupleWithIdsProg` (`Pattern.elm:556`).** Log every fresh
flex var allocated for tuple-pattern slots, with region:

    [Constrain/Pattern/Tuple] region=<region> aVar=<v> bVar=<v> cVars=<vs>

**(b) `VarLocal` references in `Compiler.Type.Constrain.Typed.Expression`.**
Find the path that types a `VarLocal name` and emits the expectation
constraint. Log:

    [Constrain/Expr/VarLocal] region=<region> name=<name> var=<v> expected=<type>

This links the flex var to its **syntactic origin** (a *file:line:col*
in the source). With Step 3's MVarId trace and Steps 4/5's
`IO.Variable` trace, we now have a chain:

    source file:line:col
      └─ Constrain (IO.Variable v)
          └─ Solve (root stays Flex)
              └─ PostSolve (Flex passes through)
                  └─ AssignMVarIds (root → MVarId 8531)
                      └─ Specialize (8531 not in subst → MVar _ CEcoValue)
                          └─ Layout (bitmap 17)
                              └─ Codegen (slot 1 boxed at construction)
                                  └─ Runtime (pointer read as i64)

### Step 7 — Run the Stage 5 self-compile and capture all traces

The buggy MLIR lives in `compiler/build-kernel/bin/eco-compiler.mlir`,
produced by **Stage 5** in `compiler/CMakeLists.txt:169–192`
(`eco-boot-2-runner.js make ... --output=bin/eco-compiler.mlir
compiler/src/Terminal/Main.elm`). This is the
*nodejs-running-the-Stage-2-compiler-on-the-compiler-sources* step,
which is what the previous trace report exercised (it called this
"Stage 3 self-compile" in different numbering).

Run:

```bash
cd /work
rm -f /tmp/trace.log
cmake --build build --target eco-compiler-mlir 2>&1 | tee /tmp/trace.log
grep -E '^\[(AssignMVarIds|Constrain|Solve|PostSolve|Specialize|TupleLayout|TupleCreate)' \
    /tmp/trace.log > /tmp/trace-summary.log
```

The expected size of `/tmp/trace.log` will be large; the
gating/windowing strategies in Steps 3–5 should keep
`/tmp/trace-summary.log` tractable.

If after Steps 1–2 the Stage 5 stderr does not contain
`[Specialize/Tuple] ... monoType = T3(I V_? CEcoValue I)` for any
3-tuple, the bug has moved/been masked since
`wrong-unboxed-bitmap.md` was written. In that case: pause, report
the new state, and revisit the plan before adding the upstream
traces.

**Small synthetic reproducer is deferred** until after the root cause
of the unconstrained TVar has been identified from the Stage 5 trace.

### Step 8 — Write the upstream trace report

Produce `plans/wrong-unboxed-bitmap-upstream.md` (sibling of
`wrong-unboxed-bitmap.md`) with the chronologically ordered story:

- where the flex var was born (Constrain) — *file:line:col* in the
  source, plus the `IO.Variable` identity;
- which solver-root it backs (Solve / SolverRoots);
- whether the solver ever unified it with `Int` (Solve trace);
- whether PostSolve had a chance to default it (PostSolve trace);
- how AssignMVarIds turned the root into MVarId 8531
  (AssignMVarIds trace);
- and the downstream consequence (already captured in
  `wrong-unboxed-bitmap.md`).

The report answers the three questions the user asked:

1. **Is this a synthetic TVar added by TypedCanonical?**
   Step 6's trace at `addTupleWithIdsProg`. Working hypothesis:
   tuple-pattern destructure creates a fresh flex var per slot.
2. **Why is it not linked to another var or to `Int`?**
   Steps 5 + 6. The traces will pick between hypothesis (A)
   (constraint never generated) and (B) (constraint generated but
   wrong root after freshening).
3. **Should this be resolved in PostSolve or Monomorphization?**
   A direct recommendation at the end, justified by the trace data.

### Step 9 — Remove all traces

Once the report is written and merged, delete every `Eco.Console.log`
call added in Steps 1–6 plus any helper functions (`shouldTraceId`,
ad-hoc pretty-printers) introduced to support them. Rebuild Stage 5
to confirm the tree is back to a clean state. Mirrors the cycle
described in `wrong-unboxed-bitmap.md`.

## Open questions / assumptions

1. **`state.ctx.currentScheme` and `state.ctx.currentFreeVars`
   accessibility.** The prior trace report logged these. Need to
   confirm they exist as accessible fields on the current
   `Compiler.Monomorphize.State.MonoState`. If not, log the closest
   equivalents (likely `state.ctx.specKey` or whatever scheme-identity
   field is current).

2. **Pretty-printers.** The prior report mentioned
   `Mono.tvarDiagnostic` (emitting e.g.
   `Tup{ T:Int{}, (V8531 inSubst=NO numberVar=N), T:Int{} }`). If that
   function was deleted with the previous traces, inline ad-hoc
   pretty-printers at each trace site rather than reintroducing a
   shared helper — keeps the diff small and the trace code easy to
   strip in Step 9.

3. **PostSolve's defaulting responsibility.** I haven't yet read
   enough of `Compiler/Type/PostSolve.elm` to know whether it
   deliberately leaves `Flex` roots alone for Monomorphize to handle,
   or whether it is the natural home for any defaulting. Step 4's
   trace should give an empirical answer. The Monomorphize phase
   *does* have a defaulting concept (the prior bug fix landed
   `Mono.forceCNumberToInt` at `Specialize.elm:3215`, and there is
   filler logic at `Specialize.elm:540`/`561`), but those clearly
   don't cover the `CEcoValue` case for `V8531`. Need to read these
   to understand what was intentionally left out before drawing
   conclusions.

4. **`Type.Solve` trace volume.** Even with name-based gating the
   Solve trace can be huge. If first-pass volume is unmanageable, the
   fallback is a two-phase trace: (a) record only the *count* and
   final content of every root in a side table dumped at end of
   Solve; (b) then re-instrument with surgical filters once Step 3
   has named the specific root.

5. **`AssignMVarIds` id window.** The `8500–8600` window is taken from
   the prior report; it assumes the bug reproduces with the same
   compilation inputs and roughly the same allocation order. If the
   trace at Step 1 shows the bitmap-17 case under a different MVarId
   range, widen Step 3's window accordingly.

6. **Rebuild stages affected.** Inserting `Eco.Console.log` into the
   compiler source means rebuilding the Stage 2 boot compiler
   (`eco-boot-2.js`) before Stage 5 will see the changes. Standard
   `cmake --build build --target eco-compiler-mlir` handles this
   automatically; calling out so we don't waste time wondering why the
   first run of the trace is silent.

## Deliverable

`plans/wrong-unboxed-bitmap-upstream.md` — a chronologically ordered
trace report that pins the source-file location at which the offending
TVar is introduced, names the phase responsible for failing to bind
it, and recommends which phase should own a future fix.

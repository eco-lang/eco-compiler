# Typechecker Design B — Direct recursion + spine loops

**Speculative rewrite (Step 8, item 1 from `plans/typechecker-simplification.md`).** Replace the
reified constraint-generation DSL with **ordinary recursive `IO` functions**, keeping stack safety
by converting only the *unbounded linear spines* of the AST walk into explicit `IO.loop`s. This is
one of two competing end-states for the constraint generator; the other is the explicit-worklist
rewrite in `typechecker-design-c.md`. **Only one of B or C is kept.**

**Prereq:** S1–S7 (`typechecker-simplification.md`) done and green, and `typechecker-more.md`
landed and green. Develop B in an **isolated git worktree** off that baseline (Design C gets its
own worktree) so the two experiments never collide and can be compared side-by-side.

## The thing being removed

Two reified DSLs survive S1–S7, and both exist purely to make the constraint walk stack-safe:

1. **`ProgS s a` / `InstrS s a`** — the shared freer-monad in
   `Compiler/Type/Constrain/Typed/Program.elm` (247 lines). `DoneS`/`StepS` + five instructions
   (`MkFlexVarS`, `MkFlexNumberS`, `GetStateS`, `ModifyStateS`, `RunIOS`), interpreted by
   `runS`/`stepS`/`stepInstrS` on top of `IO.loop`. Used by **Expression** (275 `Prog.` sites,
   `Typed/Expression.elm`) and **Module** (23 sites, `Typed/Module.elm`).
2. **`PatternProg`** — a second, smaller local DSL in `Typed/Pattern.elm`
   (`PDone`/`PMkFlexVar`/`PFromSrcType`/`PAddPatternWithIds`/`PTraverseList`, interpreted by
   `runPatternProgWithIds`/`stepProgWithIds`, `Pattern.elm:120-154`).

Every generator function is written as `Prog.opMkFlexVarS |> Prog.andThenS (\v -> Prog.opModifyS
(recordNodeVar …) |> Prog.andThenS (\() -> …))` — the readability cost the parent plan flagged.
The DSL buys exactly one thing: **construction and execution both run at constant JS-stack depth**,
because `andThenS` defers each continuation and `IO.loop` drives one instruction per iteration.

## The bet

**In real ASTs, unbounded depth is always a *linear spine* — a chain along a single child pointer —
never deep balanced branching.** Concretely, the axes along which `Can.Expr`/`Can.Pattern` depth is
unbounded are all chains:

- **`let`-chains** — right-nested `Can.Let`/`Can.LetRec`/`Can.LetDestruct` (`body` is the deep
  child; the def RHS is a *separate* expression). This is the exact axis S7 already had to defer;
  see `DeepLetStackSafetyTest`.
- **binop chains** — `1 + 2 + 3 + …` nests `Can.Binop` down one operand.
- **pipe/call chains** — `a |> f |> g |> …` and curried `Can.Call` nest down the func/first-arg.
- **`if`/`else if` chains** — nested `Can.If`.
- **access chains** — `r.a.b.c…` nests `Can.Access`.
- **module decl list** — already an explicit loop (`Module.constrainDeclsWithVarsStep`,
  `Module.elm:127-151`) and proof the approach works.

Genuine *tree* branching (a Case with N branches, a Record with N fields, a Call with N args) is
**bounded by source width, not depth**, and each child subtree's own depth is again one of the
linear axes above. A balanced expression tree of depth d holds ~2^d nodes, so d stays in the low
tens even for enormous programs. **Therefore:** walk the linear spines with explicit `IO.loop`s
(constant stack), and let the residual branching recurse directly on the JS stack (bounded in
practice). If the bet holds, the generator reads like a normal recursive typechecker with a handful
of clearly-marked spine loops, and both reified DSLs disappear.

**This bet is the risk.** It must be *proven per axis with a deep-nesting test*, not assumed.

---

## Enabler (do first): fold `NodeIdState` into `IO.State`

The DSL's `s`-threading exists only to carry `NodeIdState` (the id→var recording table +
Group-B/synthetic bookkeeping; `Typed/NodeIds.elm`). `NodeIdState` is already `Array`-backed
(`NodeIds.elm:154-159` uses `Array.set/append/push`) — i.e. it is genuinely a mutable store, the
same shape as the union-find and the S2 `NameState`.

**Change:** add a `nodeIds : NodeIdState` field to `IO.State` (`System/TypeCheck/IO.elm:136-142`),
exactly as S2 did for `names`. Provide `IO.getNodeIds`/`IO.modifyNodeIds`/`IO.withNodeIds`
(seed/run/restore, mirroring `withFreshNames`, so the erased entry point can run with recording
disabled). Then:

- `recordNodeVar`/`recordSyntheticExprVar`/`recordSchemeBinders` become plain `IO ()`
  (read-modify-write `s.nodeIds`), replacing `Prog.opModifyS (NodeIds.recordNodeVar …)`.
- `opMkFlexVarS`/`opMkFlexNumberS` were already just `Type.mkFlexVar`/`Type.mkFlexNumber` in plain
  `IO` (see the interpreter, `Program.elm:230-236`) — call them directly.
- `opGetS` (the `recording` gate read, `Expression.elm:448`) becomes `IO.getNodeIds |> IO.andThen
  (\st -> if st.recording then … else …)` — or push the recording flag into `IO.State` too.
- The generator signature collapses from `… -> ProgS ExprIdState Constraint` to `… -> IO
  Constraint`, and `Prog.andThenS`/`Prog.mapS`/`Prog.pureS` become `IO.andThen`/`IO.map`/`IO.pure`.

This alone removes all the `s`-tuple threading and makes the rest of Design B a *plain `IO`*
rewrite. (Alternative: keep threading `NodeIdState` explicitly as `… -> NodeIdState -> IO
(Constraint, NodeIdState)`. Rejected — it reintroduces exactly the tuple noise we are deleting and
does not match the codebase's mutable-store idiom. Fold into `IO.State`.)

> Note on construction-time safety: in plain `IO`, `child |> IO.andThen k` builds the closure
> `\s0 -> let (s1,a) = child s0 in k a s1` **without** evaluating `child`, so there is no
> construction-time recursion (the S7 hazard was specific to how `Prog.andThen` forced its subject).
> The remaining hazard is purely **run-time**: applying that closure runs `child s0`, which for a
> deep spine recurses one JS frame per level. That is what the spine loops fix.

---

## The rewrite

### 1. Spine loops (the core of Design B)

For each unbounded linear axis, write a two-phase `IO.loop`:

- **Descend** the chain iteratively, at each level allocating the node's var(s), recording them
  (`recordNodeVar`), and **pushing that level's context onto an accumulator list** (region, exprId,
  exprVar, and the per-node payload — e.g. the `def` for a let, the operator+annotation+other
  operand for a binop). Advance `current` to the deep child. Stop when `current` is no longer that
  node shape.
- **Constrain the leaf** `current` via the ordinary (possibly re-entrant) `constrainWithIds`.
- **Fold back up** the accumulator (reverse order), combining each frame's payload with the
  running child constraint exactly as today's arm does (e.g. `constrainDefWithIds def bodyCon` then
  `Type.exists [exprVar] (CAnd [letCon, CEqual region Lambda exprType expected])`, mirroring
  `constrainLetExprWithIdsProg`, `Expression.elm:758-784`).

Concretely, one spine loop per axis: `constrainLetSpine`, `constrainBinopSpine`,
`constrainCallSpine`/pipe, `constrainIfSpine`, `constrainAccessSpine`. The `let` family is the
cleanest (the body is the *only* deep child; def RHS recurses normally). Binop/Call/Access are
"linear along one operand, leaf on the other" — the loop descends the deep operand and the shallow
operand recurses directly (bounded).

The module decl spine already has its loop (`constrainDeclsWithVarsStep`); keep it, drop only its
`Prog` usage.

### 2. Direct recursion for everything else

All bounded-width / bounded-depth nodes (Int, Negate, single Call, If (non-chain), Case + branches,
Access (single), Update, Accessor, List, Tuple, Record, Lambda, the Group-B leaf/Var forms) become
straight `IO.andThen`/`IO.map` code. Example — today's `constrainIntWithIdsProg`
(`Expression.elm:488-`) becomes:

```elm
constrainInt region exprId expected =
    Type.mkFlexNumber
        |> IO.andThen (\var -> recordNodeVar exprId var
        |> IO.map (\() -> … CEqual … ))
```

The Group-A/Group-B recording distinction and the synthetic-var wrapper
(`constrainGenericWithIdsProg`, `Expression.elm:446-483`) are preserved verbatim, just re-expressed
in plain `IO` behind the `recording` gate.

### 3. Patterns and Module

Rewrite `Typed/Pattern.elm` the same way: delete `PatternProg`/`runPatternProgWithIds` and make
`addWithIds` a plain recursive `IO` function. Pattern nesting is also linear-spine (nested
`PCtor`/`PTuple` args are width-bounded; alias/cons chains are the only linear axis) — apply the
same spine-loop treatment if any pattern axis is unbounded (verify with a deep-pattern test).
Rewrite `Typed/Module.elm`'s `constrainEffectsWithIdsProg` (a fixed 6-var allocation,
`Module.elm:244-` — trivially direct; it is not recursive).

### 4. Delete

`Typed/Program.elm` (247 lines) and the `PatternProg` machinery in `Typed/Pattern.elm`. Remove the
`import … Program as Prog` from Expression and Module. (Erased entry `Erased/Module.constrain`
still delegates to `Typed.constrainErased`, now running the direct generator with recording off.)

---

## Enumerate-and-test discipline (the correctness backbone)

Design B is only safe if **every** unbounded axis is looped. The deliverable therefore includes:

- A written enumeration (in the module docs) of every `Can.Expr_` / `Can.Pattern_` constructor,
  classified **linear-unbounded (needs a spine loop)** vs **bounded (direct recursion OK)**, with
  the justification. This table *is* the safety argument.
- A **deep-nesting regression test per linear axis** (extend the existing
  `DeepLetStackSafetyTest`, which builds a 1000-deep `let` chain via `SourceBuilder`): add
  binop-chain, pipe/call-chain, if-chain, access-chain (and deep-pattern if applicable) at depth
  ≥10k, asserting type-check completes with no stack overflow. A missing loop shows up here as a
  crash. Adding test files needs a `cmake --preset build` reconfigure (memory
  `eco-cmake-preset-and-glob-reconfigure`).

## Byte-identity gate (same as S6)

Because the direct generator allocates the *same* fresh vars in the *same order* (the spine loops
descend in source order, identical to today's DSL descent), `Type.mkFlexVar` is called in the same
sequence ⇒ identical variable ids ⇒ identical constraint bytes. Guard this:

- Keep `TypedErasedCheckingParity` green.
- Add / reuse a **golden-constraint diff** over a corpus: capture current (post-`-more`) constraint
  output, and assert the Design-B generator reproduces it byte-for-byte. Any drift means the walk
  order changed — a spine loop that folds in the wrong order, or a var allocated at the wrong step.

## Risk

**Medium–high.** Two failure modes: (a) a missed unbounded axis → stack overflow on pathological
input (caught by the per-axis deep tests — so the tests are non-negotiable); (b) walk-order drift →
constraint bytes change (caught by the golden diff + parity suite). Mitigate by landing
axis-by-axis behind the golden diff: rewrite the leaf/bounded arms first (byte-identical, no spine
risk), then one spine loop at a time, running `elm-tests` + a deep test after each.

## Test protocol (after each landing; per `CLAUDE.md`, run once, tee, grep)

1. `cmake --build build --target elm-tests 2>&1 | tee /tmp/designb_elmtests.txt` → `Failed: 0`
   (includes `TypedErasedCheckingParity`, golden diff, and the per-axis deep tests).
2. `cmake --build build --target full 2>&1 | tee /tmp/designb_e2e.txt` → `Result: PASSED`.

Final gate before considering B "the winner": `--target stress` and a full native `bootstrap` +
gates (the DSL removal touches the compiler that compiles itself — the deep-recursion behavior must
survive self-compilation).

## Success criteria

1. `Typed/Program.elm` and `PatternProg` deleted; zero `Prog.`/`ProgS`/`PatternProg` references in
   the typechecker. `NodeIdState` lives in `IO.State`; generator functions are `… -> IO Constraint`
   / `… -> IO (State, …)`.
2. A documented linear-vs-bounded axis table, with a passing deep-nesting test for every
   linear-unbounded axis (≥10k depth).
3. Byte-identical constraint output: golden diff + `TypedErasedCheckingParity` green.
4. `elm-tests` `Failed: 0`; E2E `--target full` `Result: PASSED`; stress + bootstrap green as the
   final gate.
5. Union-find `Array` IO and `IO.loop` untouched (the spine loops *use* `IO.loop`; they do not
   modify it).

## Comparison notes (for the eventual B-vs-C decision)

Record, on completion, for the head-to-head with Design C: net line delta; how the enumerate-and-
test burden felt (did any axis surprise you?); subjective readability of the 90%-shallow code;
whether any real program hit the residual JS-stack recursion. B's thesis is *"reads like a normal
typechecker, at the cost of per-axis depth reasoning."* C's is *"uniform safety, at the cost of a
reified worklist."*

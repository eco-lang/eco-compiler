# Typechecker Design C — Explicit worklist rewrite

**Speculative rewrite (Step 8, item 2 from `plans/typechecker-simplification.md`).** Replace the
reified constraint-generation DSL with a **single explicit worklist interpreter**: one `IO.loop`
driving a hand-managed stack of pending "descend" and "combine" frames, so the *entire* walk is
iterative and constant-stack **uniformly**, with no per-node depth reasoning. This is the sibling
alternative to `typechecker-design-b.md` (direct recursion + spine loops). **Only one of B or C is
kept.**

**Prereq:** S1–S7 (`typechecker-simplification.md`) done and green, and `typechecker-more.md`
landed and green. Develop C in its **own isolated git worktree** off that baseline (Design B has a
separate worktree) so the two experiments can be built and compared independently.

## The thing being removed (same target as Design B)

The two reified DSLs that survive S1–S7 — both existing solely for stack safety:

1. **`ProgS s a` / `InstrS s a`** — `Compiler/Type/Constrain/Typed/Program.elm` (247 lines),
   interpreted by `runS`/`stepS`/`stepInstrS` over `IO.loop`. Used by **Expression** (275 `Prog.`
   sites) and **Module** (23 sites).
2. **`PatternProg`** — the local DSL in `Typed/Pattern.elm` (`PDone`/`PMkFlexVar`/`PFromSrcType`/
   `PAddPatternWithIds`/`PTraverseList`, `Pattern.elm:120-154`).

## The idea

A free monad is a *generic* reification of "the rest of the computation": its leaves capture
continuations as closures, and `IO.loop` runs them one at a time. Design C replaces that generic
machinery with a **domain-specific, defunctionalized** one: an explicit stack of frames that says,
in data, "what to constrain next" and "what to do with a child's constraint once it's built."

Crucially, **this is the `List Frame` continuation stack that S1 deleted as dead code** — but made
*real and live*. S1's finding (`typechecker-simplification.md:62-82`) was that the old
`run`/`step`/`stepInstr` threaded a `List Frame` that was *never pushed to* (always `[]`), because
the free monad already carried continuations in its leaves. Design C says: drop the free monad and
put the continuations **back into an explicit stack that actually gets pushed** — the honest,
non-dead version of that original design.

Two frame kinds:

- **`Descend expr expected`** — a subexpression still to be constrained.
- **`Combine …`** — a partially-built parent waiting on its children's constraints. One `Combine`
  variant per node shape that has children (Let, Binop, Call, If, Case, Access, Update, List,
  Tuple, Record, Lambda, …), each carrying the parent's already-allocated vars/region/expected and,
  for multi-child nodes, **which child index it is waiting on** plus the child constraints collected
  so far.

The loop maintains `(workStack : List Frame, resultReg : Maybe Constraint)`-style state and:

1. Pop a `Descend expr expected`. Allocate this node's var(s) (`Type.mkFlexVar`/`mkFlexNumber`,
   plain `IO`), `recordNodeVar`, then **push a `Combine` frame** for this node and **push a
   `Descend` for its first child** (or, for width-N nodes, arrange to descend children left to
   right). Leaves (Int, Var*, Str…) produce their `Constraint` immediately and feed it to the frame
   on top of the stack.
2. When a child constraint is produced, pop the top `Combine`. If it still has pending siblings,
   stash this child's constraint and push a `Descend` for the next sibling. If all children are in,
   run the node's combiner (build `CAnd`/`exists`/`CEqual`/`CLet` exactly as today's arm does) to
   produce *this* node's constraint, and feed it to the next frame down. When the stack empties, the
   accumulated constraint is the result.

Because the stack lives on the heap and the loop is a flat `IO.loop`, **every** node shape —
let-chains, binop chains, balanced trees, wide Case/Record — runs at constant JS-stack depth
**without any case-by-case "is this axis deep?" analysis** (the distinguishing advantage over
Design B).

---

## Enabler (do first): fold `NodeIdState` into `IO.State`

Identical to Design B's enabler (see `typechecker-design-b.md`). `NodeIdState` is already
`Array`-backed (`NodeIds.elm:154-159`); add a `nodeIds` field to `IO.State`
(`System/TypeCheck/IO.elm:136-142`) with `getNodeIds`/`modifyNodeIds`/`withNodeIds` (seed/run/
restore for the erased entry), so `recordNodeVar`/`recordSyntheticExprVar`/`recordSchemeBinders`
and the `recording` gate become plain `IO`, and fresh vars come from `Type.mkFlexVar` between loop
steps. This removes the DSL's `s`-threading and lets the worklist loop carry only its frame stack.
(The `recording` flag rides in `IO.State` too, read once per Descend to pick Group-A vs Group-B
behavior.)

---

## The rewrite

### 1. The `Frame` ADT

Define, in a new `Typed/Worklist.elm` (or inside `Typed/Expression.elm`):

```elm
type Frame
    = Descend Can.Expr (E.Expected Type)
    -- one Combine per node shape with children; carries parent context + collected child cons:
    | CombineLet   A.Region Int IO.Variable Can.Def          -- waiting on body constraint
    | CombineBinop A.Region Int … {- op, ann, operands, which side pending -}
    | CombineCall  A.Region Int IO.Variable {- func done? args collected, next arg idx -}
    | CombineIf    …
    | CombineCase  …
    | CombineList  …    -- collected element cons + remaining elements
    | CombineTuple …
    | CombineRecord …
    | CombineAccess …
    | CombineUpdate …
    | CombineLambda …
    …
```

This ADT is the **cost** of Design C: it is large (roughly one `Combine` variant per branching node
type), and multi-child variants must track sibling progress explicitly. It is the reification the
free monad hid inside closures — now paid for in visible data. Keep it defunctionalized (data, not
functions) so it stays inspectable and so byte-order is easy to reason about.

### 2. The driver

```elm
constrainWithIds : … -> IO ( Constraint, ExprIdState )   -- entry, now over IO.State.nodeIds
constrainWithIds rtv expr expected =
    IO.loop step ( [ Descend expr expected ], Nothing )
```

`step` pops a frame and returns `IO (Step …)`. `Descend` of a leaf produces a `Constraint` and
resumes combining; `Descend` of a parent allocates vars + records + pushes `Combine` + `Descend
firstChild`; each `Combine` either advances to the next sibling or finalizes and feeds the parent.
The **combiners are the existing arm bodies verbatim** — e.g. the Let combiner is
`Type.exists [exprVar] (CAnd [ constrainDefWithIds def bodyCon, CEqual region Lambda exprType
expected ])`, lifted straight out of `constrainLetExprWithIdsProg` (`Expression.elm:758-784`); the
Group-B synthetic-var wrapper (`Expression.elm:446-483`) becomes the leaf/Group-B combiner behind
the `recording` gate.

Design decision — **calls that are themselves `IO` (not sub-constraints).** Several arms call into
plain `IO` helpers mid-walk: `Pattern.addWithIds` (`Expression.elm:1506,1953`),
`constrainArgsWithIds` (`:1529,1979`), `constrainTypedArgsWithIds` (`:2031,2149`),
`argsHelpWithIds`, `Instantiate.fromSrcType`. In the worklist these are just `IO` actions run inside
a `step` before pushing the next frame — no need to reify them (they are already stack-safe on their
own). Only *sub-expression constraint generation* goes through `Descend`. This keeps the `Frame`
ADT to expression structure, not every helper.

### 3. Patterns and Module

`Typed/Pattern.elm`: `PatternProg` is already this shape in miniature (`PAddPatternWithIds` is a
descend, the others are leaf ops). Recast it as the same worklist style (or, since pattern nesting
is shallow-branching + short chains, a small dedicated `Frame` set). `Typed/Module.elm`'s
`constrainEffectsWithIdsProg` is a fixed non-recursive var allocation — rewrite as straight `IO`
(no worklist needed). The module decl spine (`constrainDeclsWithVarsStep`, `Module.elm:127`) is
already an `IO.loop`; keep it, feeding each decl's body through the worklist entry.

### 4. Delete

`Typed/Program.elm` (247 lines) and the `PatternProg` machinery. Remove `import … Program as Prog`
from Expression/Module.

---

## Byte-identity gate (same as S6 / Design B)

The worklist must **Descend children in source order** and allocate vars at the **same point** the
current DSL does (allocate-on-entry, before descending children — matching every current arm, e.g.
`opMkFlexVarS` first in `constrainLetExprWithIdsProg`). Then `Type.mkFlexVar` fires in the same
order/count ⇒ identical variable ids ⇒ identical constraint bytes. Guard with:

- `TypedErasedCheckingParity` green.
- A **golden-constraint diff** over a corpus vs the captured post-`-more` output. The single most
  likely bug in Design C is a **var-allocation-order or child-order mismatch** in a multi-child
  `Combine` (e.g. descending Call args right-to-left, or allocating the Call result var after the
  args instead of before). The golden diff is the detector; treat any drift as a frame-ordering bug,
  not an expected difference.

## Depth is free — but still test it

Unlike Design B, no per-axis depth proof is required (uniform constant stack). Still add at least
the deep `let`-chain test (`DeepLetStackSafetyTest` already exists) plus one deep *balanced*
expression and one wide node (huge Record / long Call arg list) as smoke tests that the sibling
bookkeeping and the heap stack behave at scale. Adding test files needs `cmake --preset build`
reconfigure (memory `eco-cmake-preset-and-glob-reconfigure`).

## Risk

**Medium.** The uniformity removes B's "missed axis → overflow" failure mode, but adds two of its
own: (a) the large `Frame` ADT is verbose and easy to get wrong in the multi-child sibling
bookkeeping; (b) subtle child-order / allocation-order mismatches shift constraint bytes. Both are
caught by the golden diff + parity suite. Mitigate by building the worklist node-type-by-node-type
behind the golden diff: leaves first, then single-child nodes (Let/Access/Negate), then multi-child
nodes (Call/List/Tuple/Record/Case) last, running `elm-tests` after each.

## Test protocol (after each landing; per `CLAUDE.md`, run once, tee, grep)

1. `cmake --build build --target elm-tests 2>&1 | tee /tmp/designc_elmtests.txt` → `Failed: 0`
   (includes `TypedErasedCheckingParity`, golden diff, deep/wide smoke tests).
2. `cmake --build build --target full 2>&1 | tee /tmp/designc_e2e.txt` → `Result: PASSED`.

Final gate before considering C "the winner": `--target stress` and a full native `bootstrap` +
gates (self-compilation exercises the deep-recursion behavior).

## Success criteria

1. `Typed/Program.elm` and `PatternProg` deleted; zero `Prog.`/`ProgS`/`PatternProg` references.
   `NodeIdState` in `IO.State`. Generation runs through one explicit `Frame` worklist + `IO.loop`.
2. Byte-identical constraint output: golden diff + `TypedErasedCheckingParity` green.
3. `elm-tests` `Failed: 0`; E2E `--target full` `Result: PASSED`; deep + wide smoke tests pass;
   stress + bootstrap green as the final gate.
4. Union-find `Array` IO untouched; the one `IO.loop` the worklist adds does not modify the
   trampoline primitive.

## Comparison notes (for the eventual B-vs-C decision)

Record, on completion, for the head-to-head with Design B: net line delta (C's `Frame` ADT + driver
vs B's spine loops); how verbose/error-prone the multi-child sibling bookkeeping felt; subjective
readability (C trades B's "reads like a normal typechecker" for "one uniform, provably-safe
interpreter you must read as a machine"); and whether the uniform-safety guarantee felt worth the
reification. C's thesis is *"uniform constant stack with zero depth reasoning, at the cost of a
reified worklist ADT."* B's is *"reads like ordinary recursion, at the cost of per-axis depth
proofs."* Keep whichever the team finds more maintainable; delete the other worktree.

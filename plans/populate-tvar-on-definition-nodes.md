# Populate tvar on Definition Nodes for MonoDirect

## Problem
MonoDirect crashes with "main node has no tvar" (220 test failures) because
`TOpt.TrackedDefine` and `TOpt.Define` nodes hardcode `tvar = Nothing` in their
Meta. The solver *does* assign type variables to these definitions — they're just
not threaded through.

## Fix Strategy: Two Tiers

### Tier 1: Top-level definition nodes (fixes 220 failures)

**File:** `compiler/src/Compiler/LocalOpt/Typed/Module.elm`

**Line 501 — `addDefNode`:** The `TrackedDefine` node wraps a definition whose
body is a `TCan.Expr` with a solver-assigned ID. The body goes through
`Expr.optimize` which produces a `TOpt.Expr`, but the original `TCan.Expr`'s
ID is available before optimization.

Fix: Before calling `Expr.optimize`, extract the body expression's ID and look
up its tvar from `exprVars`. Then use that tvar in the TrackedDefine Meta.

```
bodyTvar = Array.get bodyExprId exprVars |> Maybe.andThen identity
-- ...
TOpt.TrackedDefine region def deps { tipe = defType, tvar = bodyTvar }
```

The body expression's ID comes from the `TCan.Expr` (`Can.Def` contains the
body as `A.Located ExprInfo`, where `ExprInfo` has `.id`). We need to extract
this ID before optimization discards it.

**Line 200 — `addAlias`:** Synthetic record constructor. Has no solver variable.
Two options:
  (a) Keep `Nothing` and make `specializeDefineNode` handle it (revert to
      non-crashing fallback for synthetic nodes), or
  (b) Assign a tvar during alias construction in the solver/TypedCanonical phase.

Option (a) is simpler: alias constructors are monomorphic record builders.
Their types are fully concrete so `resolveType` with `Nothing` could use
a direct concrete-type conversion (like the destructor fallback).

**Lines 288/308 — `addPort`:** Synthetic port nodes. Same situation as aliases.
Keep `Nothing` and handle gracefully in MonoDirect (ports have concrete types).

### Tier 2: Let-bound definitions (may cause additional crashes)

**File:** `compiler/src/Compiler/LocalOpt/Typed/Expression.elm`

**Lines 808/850 — `optimizeDefHelp` (Let):**
The Let expression wraps a definition. The original `Can.Def` has a body
expression with a solver ID. Thread this ID through so the Let Meta gets a tvar.

Approach: In `optimizeDefHelp`, before optimizing the definition body, extract
the body expression's ID from the `Can.Def`. After optimization, use the
looked-up tvar for the Let Meta.

**Lines 848/932 — TrackedFunction in let-bindings:**
Same approach — extract the original function body's expression ID and look up
its tvar from `exprVars`.

**Line 987 — `wrapDestruct`:**
This is a utility function without access to `exprVars`. The Destruct node it
wraps is an intermediate binding. Two options:
  (a) Pass `exprVars` and the relevant ID through, or
  (b) Keep `Nothing` and handle gracefully in MonoDirect.

Option (b) is simpler: the Destruct node's type is `bodyType` (the type of the
inner expression), which is typically already resolved.

**Line 1155 — PRecord field Destructor:**
Already handled by `resolveDestructorType` fallback in MonoDirect/Specialize.elm.
Could be improved by using `makeDestructorMeta` with `effectivePatId`, but the
effectivePatId is for the *record pattern*, not the individual field. The solver
variable for the record pattern resolves to the record type, not the field type.
Needs a solver query to extract field types from a record variable.

## Implementation Order

1. Fix line 501 in Module.elm (extract body expr ID, look up tvar) — fixes 220 failures
2. Soften the crash in `specializeDefineNode` and `resolveType` for synthetic
   nodes (aliases, ports) — use `resolveDestructorType`-style fallback
3. Fix lines 808/848/850/932 in Expression.elm (thread body expr IDs through)
4. Leave line 987 and 1155 with `Nothing` + graceful fallback

## Key Insight

The canonical AST `Can.Def` contains the body as `A.Located { id : Int, node : Can.Expr_ }`.
The `id` field is the expression/node ID that maps into `ExprVars`. We need to
extract this ID *before* optimization transforms the expression, then carry the
looked-up tvar forward into the Meta of the optimized node.

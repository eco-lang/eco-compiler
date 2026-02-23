# Fix Recursive Let Placeholder Binding in MLIR Generation

## Problem

In recursive `let` groups (e.g., `Array.foldr`'s `helper`), the MLIR codegen installs
placeholder SSA variables (like `%helper`) via `addPlaceholderMappings` so that sibling
closures can capture each other. However, the generated bound expression uses a *fresh*
SSA id (like `%0`) as its result — so `%helper` is never actually **defined** as an SSA
variable. This produces invalid MLIR: `%helper` appears as an operand (captured by
closures) but has no corresponding definition.

## Root Cause

In `generateLet` (Expr.elm:2838–2961), the `Mono.MonoDef` branch generates the bound
expression and then maps the let-bound name to `exprResult.resultVar` (the fresh id).
It never connects this back to the placeholder `%name` that was pre-installed.

## Solution

Force the bound expression's result SSA id to match the placeholder `%name` that
`addPlaceholderMappings` installed. This way the defining op (e.g., `eco.papCreate`)
produces `%helper` directly, and the placeholder used by sibling closures resolves to
a real definition.

## Files Changed

**Single file:** `compiler/src/Compiler/Generate/MLIR/Expr.elm`

No new imports needed — `MlirRegion(..)`, `OrderedDict`, and all other types are
already imported.

## Detailed Steps

### Step 1: Add SSA rename helpers (after `emptyResult`, ~line 84)

Add four mutually recursive helpers that rename an SSA variable throughout the MLIR
op tree, including nested regions:

```elm
{-| Rename an SSA variable in a list of MlirOps, recursing into nested regions.

Replaces all occurrences of `fromVar` with `toVar` in:
  - op.id (the result SSA name)
  - op.operands (input SSA names)
  - Nested regions → blocks → body ops and terminators (recursive)

This is used by generateLet to force the result SSA id to match a pre-installed
placeholder (e.g., "%helper") so that mutually recursive closures can safely
capture each other via currentLetSiblings.
-}
renameSsaVarInOps : String -> String -> List MlirOp -> List MlirOp
renameSsaVarInOps fromVar toVar ops =
    let
        renameVar : String -> String
        renameVar v =
            if v == fromVar then
                toVar
            else
                v

        renameOp : MlirOp -> MlirOp
        renameOp op =
            { op
                | id = renameVar op.id
                , operands = List.map renameVar op.operands
                , regions = List.map (renameSsaVarInRegion fromVar toVar) op.regions
            }
    in
    List.map renameOp ops


renameSsaVarInRegion : String -> String -> MlirRegion -> MlirRegion
renameSsaVarInRegion fromVar toVar (MlirRegion r) =
    MlirRegion
        { entry = renameSsaVarInBlock fromVar toVar r.entry
        , blocks = OrderedDict.map (\_ block -> renameSsaVarInBlock fromVar toVar block) r.blocks
        }


renameSsaVarInBlock : String -> String -> MlirBlock -> MlirBlock
renameSsaVarInBlock fromVar toVar block =
    { block
        | body = renameSsaVarInOps fromVar toVar block.body
        , terminator = renameSsaVarInSingleOp fromVar toVar block.terminator
    }


renameSsaVarInSingleOp : String -> String -> MlirOp -> MlirOp
renameSsaVarInSingleOp fromVar toVar op =
    let
        renameVar v =
            if v == fromVar then
                toVar
            else
                v
    in
    { op
        | id = renameVar op.id
        , operands = List.map renameVar op.operands
        , regions = List.map (renameSsaVarInRegion fromVar toVar) op.regions
    }
```

Note: `MlirBlock` is a type alias (from `Mlir.Mlir`) with fields `args`, `body`,
`terminator`. It is NOT re-exported by `Mlir.Mlir exposing (...)` in Expr.elm's
current import — but since it's a type alias, we can construct/destructure records
directly without needing to import the name. The `MlirRegion` constructor IS
imported via `MlirRegion(..)`.

We do NOT rename in `block.args` because block arguments are distinct SSA bindings
(they define new names in their block's scope). The variable we're renaming is from
the enclosing let-binding scope, not a block parameter.

### Step 2: Add `forceResultVar` helper (immediately after rename helpers)

```elm
{-| Force an ExprResult to use a specific SSA id as its resultVar.

If the expression's resultVar already matches `desiredVar`, this is a no-op.
Otherwise it renames all uses/defs of the old resultVar to `desiredVar` throughout
the ops (including nested regions), and updates resultVar accordingly.

Used by generateLet to ensure that let-bound names in a recursive group define
the same SSA var that closures captured via currentLetSiblings' placeholders.
-}
forceResultVar : String -> ExprResult -> ExprResult
forceResultVar desiredVar exprResult =
    if exprResult.resultVar == desiredVar then
        exprResult

    else
        let
            renamedOps =
                renameSsaVarInOps exprResult.resultVar desiredVar exprResult.ops
        in
        { exprResult
            | ops = renamedOps
            , resultVar = desiredVar
        }
```

### Step 3: Modify the `Mono.MonoDef` branch of `generateLet` (~line 2878)

Current code (lines 2879–2892):
```elm
Mono.MonoDef name expr ->
    let
        exprResult : ExprResult
        exprResult =
            generateExpr ctxWithPlaceholders expr

        ctx1 : Ctx.Context
        ctx1 =
            Ctx.addVarMapping name exprResult.resultVar exprResult.resultType exprResult.ctx
                |> Ctx.addDecoderExpr name expr
```

Replace with:
```elm
Mono.MonoDef name expr ->
    let
        -- Look up the placeholder SSA var installed by addPlaceholderMappings.
        -- This is "%name" with type !eco.value for each let-bound name.
        ( placeholderVar, _ ) =
            Ctx.lookupVar ctxWithPlaceholders name

        -- Generate the bound expression with placeholders in scope.
        rawResult : ExprResult
        rawResult =
            generateExpr ctxWithPlaceholders expr

        -- Force the bound expression's result SSA id to be the placeholder var.
        -- This ensures that:
        --
        --   1. The placeholder (%helper) that sibling closures captured via
        --      currentLetSiblings now has a real definition (the papCreate op).
        --
        --   2. Any further uses of the let-bound name (in the body) will
        --      refer to %helper, which is now dominantly defined.
        --
        -- For recursive closures this creates a self-capture pattern where the
        -- eco.papCreate op both defines %helper and uses it as a captured operand.
        -- This is valid SSA: an operation may reference its own result.
        exprResult : ExprResult
        exprResult =
            forceResultVar placeholderVar rawResult

        -- Update varMappings for this name to use the placeholder SSA var,
        -- but refine the MLIR type to the actual result type (usually !eco.value).
        ctx1 : Ctx.Context
        ctx1 =
            Ctx.addVarMapping name placeholderVar exprResult.resultType exprResult.ctx
                |> Ctx.addDecoderExpr name expr
```

The rest of the `Mono.MonoDef` branch (body generation, `outerSiblings` restoration,
`finalIsTerminated` logic) remains **exactly as-is**.

## Why This Works

1. **`addPlaceholderMappings`** installs `name → { ssaVar = "%name", mlirType = !eco.value }`.
2. **`currentLetSiblings`** captures these placeholders so sibling closures reference `%name`.
3. **`forceResultVar`** renames the generated op's result from `%0` to `%name`, so
   `%name` is now **defined** by the `eco.papCreate` (or whatever op produces the value).
4. The op can legally use `%name` as both its result and an operand (self-capture) —
   MLIR SSA allows an operation to reference its own result.

## What Does NOT Change

- `addPlaceholderMappings` — unchanged
- `collectLetBoundNames` — unchanged
- `currentLetSiblings` setup — unchanged
- `Mono.MonoTailDef` branch — unchanged
- Closure lowering / EcoToLLVM — unchanged
- GlobalOpt / Monomorphization — unchanged
- `isTerminated` propagation — unchanged

## Safety Analysis

- **Non-recursive lets**: `addPlaceholderMappings` skips names already in `varMappings`.
  For truly non-recursive bindings that are new, the rename is purely cosmetic (better
  SSA names) with no semantic effect.
- **Recursive lets**: The core fix. `%helper` is defined by the closure-construction op
  and self-captured. This is the standard SSA pattern for recursive closures.
- **Mutually recursive lets**: Each sibling gets its own placeholder. When sibling A
  captures `%B`, that placeholder will be defined when B's binding is processed. The
  linear let-chain ordering ensures earlier bindings are defined before later ones
  reference them.
- **Region recursion**: The rename traverses into nested regions (eco.case alternatives,
  eco.if branches, etc.) so if the let-bound result var is referenced inside a nested
  op's region, the rename is applied consistently.

## Testing

- Run `cmake --build build --target check` to verify E2E tests pass (especially
  `Array.foldr`, `Array.foldl`, `Array.builderFromArray`).
- Run `cd compiler && npx elm-test-rs --fuzz 1` for front-end tests.
- Consider adding a targeted test case with a recursive let binding if one doesn't
  exist already.

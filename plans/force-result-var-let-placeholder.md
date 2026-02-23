# Plan: Make Recursive Let RHS Define Placeholder SSA Var Directly

## Status: Already Implemented — Test Coverage Needed

The design is **fully implemented** in `Expr.elm`. All design questions have been resolved. The remaining actionable item is adding dedicated let-rec codegen tests.

---

## Problem

For a recursive `let` like:

```elm
let
    helper = \node acc -> ... helper ...
in
    body
```

The compiler installs a placeholder mapping `helper -> { ssaVar = "%helper", mlirType = !eco.value }` before generating the RHS. Closures that capture `helper` during RHS generation use `%helper` as an operand. But the RHS itself produces a fresh result var (e.g. `%0`), leaving `%helper` undeclared in the SSA.

The fix: force the RHS's result SSA id to **be** `%helper`, so the defining op (`eco.papCreate`) directly defines the placeholder that siblings captured.

---

## Implementation (Already Present)

### 1. SSA Rename Helpers (`Expr.elm:87–156`)

- `renameSsaVarInOps : String -> String -> List MlirOp -> List MlirOp`
- `renameSsaVarInRegion : String -> String -> MlirRegion -> MlirRegion`
- `renameSsaVarInBlock : String -> String -> MlirBlock -> MlirBlock`
- `renameSsaVarInSingleOp : String -> String -> MlirOp -> MlirOp`

Properties:
- Recurses into nested regions and blocks (correct for MLIR SSA scoping).
- Does **not** touch block arguments (they define new SSA bindings).
- Only renames exact matches of `fromVar` → `toVar`.

### 2. `forceResultVar` (`Expr.elm:159–182`)

```elm
forceResultVar : String -> ExprResult -> ExprResult
```

If `exprResult.resultVar == desiredVar`, no-op. Otherwise renames all occurrences of the old `resultVar` to `desiredVar` in the ops list, and updates `resultVar`.

Safety argument:
- `resultVar` is by construction the unique SSA id of the RHS value.
- Renaming is scoped to `exprResult.ops` only — not the enclosing function.
- No collision with unrelated `%0`-style vars outside this ops list.

### 3. `generateLet` wiring (`Expr.elm:2936–3081`)

For `MonoDef name expr`:

1. `addPlaceholderMappings` installs `%name` into `varMappings` + `currentLetSiblings`.
2. `Ctx.lookupVar ctxWithPlaceholders name` retrieves the placeholder SSA id.
3. `generateExpr ctxWithPlaceholders expr` produces `rawResult` (result is some `%N`).
4. `forceResultVar placeholderVar rawResult` rewrites `%N` → `%name` throughout.
5. `Ctx.addVarMapping name placeholderVar exprResult.resultType ...` updates mappings with actual MLIR type.
6. Body is generated in updated context where `name → %name`.

### 4. Files Touched

Only `compiler/src/Compiler/Generate/MLIR/Expr.elm`. No changes to Context.elm, Functions.elm, or Closures.elm.

---

## Correctness Analysis

### Why no collisions

- `exprResult.resultVar` (`%N`) is a unique fresh var from `Ctx.freshVar`.
- Renaming is limited to `exprResult.ops` — the ops generated solely by the RHS expression.
- No other value in this ops list uses `%N` as a definition (only the final op defines it).
- The target `%name` was reserved by `addPlaceholderMappings` and not used as a definition by any prior op.

### Self-referential SSA

After `forceResultVar`, a recursive closure produces:

```mlir
%helper = eco.papCreate %helper, %func : ...
```

This is valid MLIR SSA: an operation may reference its own result in its operands. The semantics is that `%helper` is defined by this op, and the operand `%helper` refers to the same value (the closure under construction captures itself).

### Edge cases

1. **Non-recursive let**: `forceResultVar` still runs but is harmless — it just renames `%0` → `%name`.
2. **Already matching**: If `resultVar == placeholderVar`, it's a no-op.
3. **Nested regions in RHS**: The rename recurses into regions, so closure bodies that reference `%0` also get updated.
4. **MonoTailDef**: The `MonoTailDef` branch does **not** use `forceResultVar` — it takes a different code path (loop-based). This is correct since tail-recursive functions don't produce a closure value.

---

## Resolved Questions

### Q1. Mutual recursion type asymmetry — **Intentional and safe**

`currentLetSiblings` is built **once** from `groupVarMappings` before any RHS is generated, so every sibling closure sees every other sibling as `!eco.value` regardless of processing order. This is the correct conservative choice: sibling closures captured into other closures should always be `!eco.value` (opaque closure pointers).

`varMappings` is then refined per-binding after each RHS completes (step 5), so later uses in the let body see the precise type. The asymmetry only affects the sibling capture path, where `!eco.value` is the right representation.

### Q2. `MonoTailDef` placeholder — **Not an active bug (latent hazard)**

TailDef names get placeholders in `currentLetSiblings` but the TailDef branch doesn't call `forceResultVar`. This is safe because:
- TailDefs are used via `MonoTailCall` → `eco.joinpoint`/`eco.jump`, not captured into closures.
- The pipeline never constructs a closure that captures a TailDef name as a free variable.
- The placeholder mapping exists but is never consumed by closure capture paths.

**Latent hazard**: If future changes ever allow capturing local TailDefs into closures, the TailDef branch would need to mirror the MonoDef path (generate a closure value + `forceResultVar`).

### Q3. Test coverage — **Indirect only, dedicated tests recommended**

The mechanism is exercised indirectly through Array/JsArray tests and global SSA invariants (e.g. `CheckEcoClosureCaptures`). There are no dedicated unit tests for:
- Self-recursive let closures
- Mutually recursive let closures
- Non-recursive lets through this path
- Nested let-rec groups

See "Remaining Work" below.

### Q4. Threading `desiredVar` — **Not worth it now**

The current `forceResultVar` approach is localized (only `Expr.elm`), safe (scoped rename), and avoids an invasive change to the `generateExpr` signature and all its call sites. A threaded `desiredVar` parameter would only be warranted if more use cases emerge for pre-allocated result ids.

### Q5. `isTerminated` preservation — **Cannot be affected**

`forceResultVar` only touches `ops` (via `renameSsaVarInOps`) and `resultVar`. It does not modify `isTerminated`. Renaming an SSA id does not change whether the expression ends with a terminator; `isTerminated` is a semantic property of the control flow, not of SSA naming.

---

## Remaining Work

### Add dedicated let-rec codegen tests

No code changes are needed. The only gap is test coverage. Recommended test cases:

1. **Self-recursive let closure** — e.g. `Array.foldr` helper pattern:
   ```elm
   let
       f = \n -> if n == 0 then 0 else f (n - 1)
   in
   f 5
   ```
   Assert: `%f` is defined exactly once, by a closure construction op.

2. **Mutually recursive let closures** — two closures capturing each other:
   ```elm
   let
       even n = if n == 0 then True else odd (n - 1)
       odd  n = if n == 0 then False else even (n - 1)
   in
   even 10
   ```
   Assert: `%even` and `%odd` are each defined once; each captures the other via `currentLetSiblings`.

3. **Non-recursive let** — verify `forceResultVar` is benign:
   ```elm
   let
       x = 42
   in
   x + 1
   ```
   Assert: `%x` is defined, no stale `%N` references remain.

4. **Nested let-rec groups** — inner group with separate placeholder scope:
   ```elm
   let
       outer = \n ->
           let
               inner = \m -> inner (m - 1)
           in
           inner n
   in
   outer 5
   ```
   Assert: `%inner` is scoped correctly and doesn't collide with `%outer`'s placeholder.

These tests should check MLIR-level output (SSA id definitions and uses) rather than runtime behavior, to directly validate the `forceResultVar` mechanism.

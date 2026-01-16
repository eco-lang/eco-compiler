# Fix: Nested Mutually Recursive Let Bindings in MLIR Codegen

## Problem

When generating MLIR for nested mutually recursive let bindings, `lookupVar` fails with:

```
lookupVar: Failed to find inner2 in [outer]
```

Test case:
```elm
outer n =
    let
        inner1 x = if True then 0 else inner2 x
        inner2 x = inner1 x
    in
    inner1 n
```

## Root Cause

In `generateClosure`, `siblingMappings` is set to `ctx.varMappings` at closure-creation time. However, this snapshot may come from an outer scope that doesn't have the inner let-group's placeholders yet.

The `siblingMappings` captured when creating `inner1`'s closure only contains `{outer: ...}` instead of `{outer: ..., inner1: ..., inner2: ...}`.

## Solution

Add `currentLetSiblings` field to Context with lexical scoping semantics:
- **On entry** to a let-rec group: set `currentLetSiblings` to the group's placeholder mappings
- **On exit**: restore `currentLetSiblings` to its previous value
- **In closures**: use `currentLetSiblings` if non-empty, otherwise fallback to `varMappings`

## Implementation

### Step 1: Add `currentLetSiblings` to Context

**File:** `compiler/src/Compiler/Generate/MLIR/Context.elm`

Add field to `Context` type alias and initialize to `Dict.empty` in `initContext`.

### Step 2: Update `generateLet` with lexical scoping

**File:** `compiler/src/Compiler/Generate/MLIR/Expr.elm`

- Save `ctx.currentLetSiblings` as `outerSiblings` on entry
- Set `currentLetSiblings` to the group's placeholder mappings
- Restore `outerSiblings` on exit from the let-rec group

### Step 3: Update `generateClosure` to use `currentLetSiblings`

**File:** `compiler/src/Compiler/Generate/MLIR/Expr.elm`

Use `ctx.currentLetSiblings` for `siblingMappings` if non-empty, otherwise fallback to `ctx.varMappings` (preserves existing behavior for non-let-rec closures).

## Files Modified

| File | Changes |
|------|---------|
| `Context.elm` | Add `currentLetSiblings` field, initialize to `Dict.empty` |
| `Expr.elm` | `generateLet`: save/restore `currentLetSiblings` on entry/exit |
| `Expr.elm` | `generateClosure`: use `currentLetSiblings` with fallback |

## Key Design Decisions

1. **Fallback to `varMappings`** for closures outside let-rec groups preserves existing behavior
2. **Lexical scoping** via save/restore ensures inner group names don't leak into unrelated scopes
3. **`currentLetSiblings` includes outer names** via building on top of `ctx.varMappings`

# Fix: closure capture / variable substitution misses MonoDestruct paths and MonoCase deciders

## Problem

Two related bugs in the optimizer and closure capture analysis:

### Bug 1: `collectVarTypes` misses MonoDestruct paths (67 test failures)

`computeClosureCaptures` in `compiler/src/Compiler/Monomorphize/Closure.elm` crashes with:

```
computeClosureCaptures: missing type for captured var `w`; this violates Mono typing invariants
```

Root cause: asymmetry between `findFreeLocals` (which traverses MonoDestruct paths via `findPathFreeLocals`) and `collectVarTypes` (which only recurses into the body, ignoring the path).

### Bug 2: `substitute` skips MonoCase decider trees (48 test failures)

After fixing Bug 1, `lookupVar` in MLIR codegen crashes with:

```
lookupVar: unbound variable w (available: dummy, mono_inline_0)
```

Root cause: `substitute` in `MonoInlineSimplify.elm` correctly handles MonoCase's `rootName` and `branches`, but passes the `decider` tree through **unchanged**. When the decider contains `Leaf (Inline expr)` leaves with MonoDestruct nodes referencing a variable being substituted, those references aren't renamed.

Discovered via crash-based debugging: adding `Debug.todo` to `substitute`'s MonoClosure case confirmed `substitute` was called with `old=w, new=mono_inline_0, bodyType=Case`. The body was a MonoCase (not MonoDestruct directly), and the MonoDestruct with `MonoRoot "w"` was inside the decider's `Inline` leaf.

## Fixes Applied

### Fix 1: `collectVarTypes` path traversal (Closure.elm)

Added `collectPathVarTypes` helper and updated `MonoDestruct` case in `collectVarTypesHelper`.

**File:** `compiler/src/Compiler/Monomorphize/Closure.elm`

### Fix 2: `substitute` decider traversal (MonoInlineSimplify.elm)

Added `substituteDecider` helper and updated `MonoCase` case in `substitute` to recurse into the decider tree.

**File:** `compiler/src/Compiler/GlobalOpt/MonoInlineSimplify.elm`

### Fix 3: Consistency fixes for other functions (MonoInlineSimplify.elm)

Applied the same decider/path traversal fix to all functions that process the AST:

| Function | MonoDestruct path | MonoCase decider |
|---|---|---|
| `substitute` | Already handled | **Fixed** — added `substituteDecider` |
| `countUsages` | Already handled (`countUsagesInPath`) | **Fixed** — added `countUsagesInDecider` |
| `inlineVar` | **Fixed** — added `inlineVarInPath` with shadowing check | **Fixed** — added `inlineVarInDecider` |
| `rewriteExpr` | N/A (paths have no expressions) | **Fixed** — added `rewriteDecider` |
| `simplifyLets` | N/A (paths have no expressions) | **Fixed** — added `simplifyLetsDecider` |

## Verification

All 7865 tests pass after both fixes.

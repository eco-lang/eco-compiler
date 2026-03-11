# Plan: Extend CEco→MErased Erasure to Benign Polymorphic Cycles

## Goal

Extend `patchNodeTypesCEcoToErased` to cover `MonoCycle` nodes so that benign
polymorphic cycles (like `process []` and `Box a`) have their phantom CEcoValue
MVars erased to MErased, while buggy monomorphic cycles remain fully visible to
MONO_021.

## Background

The existing key-type-aware gating in `monomorphizeFromEntry` already
distinguishes benign polymorphic cycles from buggy ones:

- **Benign**: key type contains `MVar _ CEcoValue` → `keyHasCEcoMVar == True`
- **Buggy**: key type is monomorphic (e.g. `List Int -> List Int`) → `keyHasCEcoMVar == False`

The only gap is that `patchNodeTypesCEcoToErased` currently skips `MonoCycle`
nodes entirely. No other changes are needed — the gating logic already does the
right thing.

## Existing Infrastructure (no changes needed)

### Type-level helpers (`Monomorphized.elm`)
- `containsCEcoMVar` — detects polymorphic CEco key types
- `eraseCEcoVarsToErased` — replaces `MVar _ CEcoValue` → `MErased`, preserves `CNumber`

### Expression-level helpers (`Monomorphize.elm`)
- `mapExprTypes` / `mapOneExprType` — generic expression type rewriter
- `eraseExprCEcoVars` — applies `eraseCEcoVarsToErased` to all expr annotations

### Key-type-aware gating (`monomorphizeFromEntry`)
- Dead-value specs → `patchNodeTypesToErased` (all MVars erased)
- Value-used + polymorphic key → `patchNodeTypesCEcoToErased` (only CEco erased)
- Value-used + monomorphic key → no patch (any CEco MVar is a real bug)

## Code Changes

### Step 1: Extend `patchNodeTypesCEcoToErased` to handle `MonoCycle`

**File**: `compiler/src/Compiler/Monomorphize/Monomorphize.elm`

Add a `MonoCycle` case to `patchNodeTypesCEcoToErased`:

```elm
Mono.MonoCycle defs t ->
    Mono.MonoCycle
        (List.map (\( name, expr ) -> ( name, eraseExprCEcoVars expr )) defs)
        (Mono.eraseCEcoVarsToErased t)
```

Update the comment from:
```
-- Do NOT patch: cycles (preserve MONO_021 visibility), ports (ABI obligations),
-- externs/managers (kernel ABI), ctors/enums (no MVars in practice)
```
to:
```
-- Do NOT patch: ports (ABI obligations), externs/managers (kernel ABI),
-- ctors/enums (no MVars in practice). Cycles are only patched when their
-- key type still contains CEcoValue MVars (see key-type-aware gating in
-- monomorphizeFromEntry).
```

### Step 2: No changes to gating logic

The existing `patchedNodes` logic in `monomorphizeFromEntry` already gates on
`keyHasCEcoMVar`. When `True`, `patchNodeTypesCEcoToErased` is called — and
with Step 1 it will now also handle `MonoCycle`. When `False`, the cycle is
left untouched and MONO_021 can catch any leaked CEcoValue MVars.

### Step 3: Run tests

```bash
cd /work/compiler && npx elm-test-rs --project build-xhr --fuzz 1
```

Verify:
- The 2 remaining MONO_021 failures ("Lambda in record update", "Identity
  composition") are unchanged — these are `MonoDefine`/`MonoClosure` issues,
  not cycles.
- The benign cycle test cases pass all invariant suites.

## Behaviour Summary

| Scenario | Key type has CEco? | Patched? | MONO_021 visible? |
|---|---|---|---|
| `process []` (benign poly cycle) | Yes | Yes → MErased | No (erased) |
| `f Box` / `g Box` (phantom cycle) | Yes | Yes → MErased | No (erased) |
| Buggy monomorphic cycle (`List Int`) | No | No | Yes (caught) |
| Dead-value spec (any) | N/A | Yes (full erase) | N/A (pruned) |

## Risks

- **Low risk**: `eraseExprCEcoVars` already handles all `MonoExpr` variants
  recursively. Applying it to cycle binding expressions is the same as applying
  it to define/tailfunc bodies.
- **No ABI impact**: MErased maps to `!eco.value` at all boundaries (per the
  prior change to `monoTypeToAbi`/`monoTypeToOperand`/`processType`).
- **MONO_021 still guards monomorphic cycles**: The key-type gate ensures we
  never mask a real specialization bug.

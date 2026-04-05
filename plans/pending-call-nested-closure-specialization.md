# Plan: Pending Closure Representation for Nested Calls

## Goal

When a call expression (which may be a partial application) is passed as an argument to another call, delay specializing that inner call until we know the expected parameter type at the outer call site. This lets us push additional constraints (from the outer combinator's scheme) into the inner partial application's types, instead of permanently baking in a too-generic `MVar _ CEcoValue` ABI.

## Motivation

Combinator-heavy code like `b = s (k s) k` or operator sections like `((+) 1)` passed into `sp` currently get specialized too eagerly. The inner call (`k s`, `(+) 1`) is specialized *before* the outer callee's parameter type is known, resulting in overly generic closure ABIs that cause SIGSEGV/SIGABRT and wrong list tails at runtime.

The existing `PendingGlobal` mechanism already solves this problem for polymorphic globals — we extend the same pattern to call expressions.

## File Changed

**Only** `compiler/src/Compiler/Monomorphize/Specialize.elm`

## Design Decisions (Resolved)

### D1: Defer only polymorphic calls, not all calls

Do **not** defer every `TOpt.Call` unconditionally. Defer only when the provisional result type still has unresolved MVars (`Mono.containsCEcoMVar`). If already fully monomorphic, specialize immediately and produce `ResolvedArg`. This keeps the common monomorphic cases cheap and targets exactly the problematic higher-order / partial-application cases.

### D2: `refineSubstFromArgExprs` and `PendingCall` are complementary

They solve different problems and both stay:
- `refineSubstFromArgExprs` pushes information *from argument expressions* into the substitution (elements, fields, lambdas in containers). It reduces residual MVars before looking at the callee scheme.
- `PendingCall` handles holes that remain *after* we've used the args, unified with the callee scheme, but still lack constraints from the *consumer* of the call result.
- `refineSubstFromArgExprs` will sometimes avoid needing `PendingCall`, but cannot replace it.

### D3: Use `applySubstFV` for provisional types

Use `applySubstFV` (i.e. `TypeSubst.applySubstWithFreeVars`) for computing provisional mono types of call args. It respects the current global's `FreeVars` and avoids cross-scheme contamination. Plain `applySubst` would be more dangerous since `unifyCallSiteDirect` works on a freshened copy of the callee scheme.

### D4: Nested `PendingCall` works via recursion

`f (g (h x))` as an argument: the outer `g (h x)` becomes `PendingCall`. When resolved, `specializeExpr` runs on it, which calls `processCallArg` for `h x`, potentially creating another `PendingCall`. This is resolved left-to-right by `resolveProcessedArgs`. No extra machinery needed — just test explicitly.

### D5: No evaluation order concern for operator sections

Elm is pure; specialization is compile-time. Operator sections like `((+) 1)` have no side effects. Deferring specialization doesn't change evaluation order. Only ABI correctness matters, which `PendingCall` improves.

## Steps

### Step 1: Extend `ProcessedArg` type (line ~56-61)

Add `PendingCall` constructor after `PendingGlobal`:

```elm
type ProcessedArg
    = ResolvedArg Mono.MonoExpr
    | PendingAccessor A.Region Name (Can.Type MVarId)
    | PendingKernel A.Region String String String (Can.Type MVarId)
    | PendingGlobal (TOpt.Expr MVarId) Substitution (Can.Type MVarId)
    | PendingCall (TOpt.Expr MVarId) Substitution (Can.Type MVarId)
    | LocalFunArg Name (Can.Type MVarId)
```

Fields: `PendingCall savedExpr savedSubst canType`
- `savedExpr` — the original `TOpt.Call` expression node
- `savedSubst` — the substitution at the time we encountered this arg
- `canType` — the canonical type of the call expression (`meta.tipe`)

### Step 2: Add `TOpt.Call` arm to `processCallArg` (insert before the `_ ->` catch-all at line ~2520)

Add a new top-level arm of the outer `case arg of`, between the `TOpt.TrackedVarLocal` case (line ~2518) and the `_ ->` fallback (line ~2520):

```elm
        TOpt.Call _ _ _ meta ->
            let
                canType =
                    meta.tipe

                monoType =
                    Mono.forceCNumberToInt (applySubstFV st subst canType)
            in
            if Mono.containsCEcoMVar monoType then
                -- Inner call result is still polymorphic. Defer specialization
                -- until we know the outer callee's expected parameter type.
                ( PendingCall arg subst canType :: accArgs
                , monoType :: accTypes
                , st
                )

            else
                -- Fully monomorphic result — specialize immediately.
                let
                    ( monoExpr, st1 ) =
                        specializeExpr arg subst st
                in
                ( ResolvedArg monoExpr :: accArgs
                , Mono.typeOf monoExpr :: accTypes
                , st1
                )
```

**Key:** The `containsCEcoMVar` guard ensures only polymorphic/incomplete call results are deferred. Monomorphic calls are specialized eagerly as before.

### Step 3: Add `PendingCall` branch to `resolveProcessedArg` (insert after `PendingGlobal` branch at line ~643)

```elm
        PendingCall savedExpr savedSubst canType ->
            -- Nested call used as argument. Now that we know the callee's
            -- expected parameter type, refine the substitution and specialize.
            let
                refinedSubst =
                    case maybeParamType of
                        Just paramType ->
                            Tuple.first (TypeSubst.unifyExtend state.ctx.mvarEnv canType paramType savedSubst)

                        Nothing ->
                            savedSubst
            in
            specializeExpr savedExpr refinedSubst state
```

Identical in structure to the `PendingGlobal` branch.

### Step 4: Build and test

```bash
# Primary regression suite — combinator tests
TEST_FILTER=Combinator cmake --build build --target full

# Full E2E suite
cmake --build build --target full
```

## Regression Test Suite

Use existing failing `elm/Combinator` tests as primary validation:

- `CombinatorBComposeTest`
- `CombinatorCFlipTest`
- `CombinatorCConsTest`
- `CombinatorBSumMapTest`
- `CombinatorSpMulTest`
- `CombinatorTThrushTest`
- `CombinatorTPipeTest`
- `CombinatorTest`
- `CombinatorListStringTest`

Consider adding focused tests:
- Simple partial application: `let f g x = g x in let h = f (\y -> y+1) in h 3`
- Nested without combinators: `let f g x = g x in let g h = f (f h) in ...`

## Behavioral Expectations

After this change:
- Inner calls like `k s` in `s (k s) k` become `PendingCall` args to `s` (because their result type has unresolved MVars)
- When `resolveProcessedArg` runs, the outer callee's parameter type refines the inner call's substitution via `unifyExtend`
- This closes MVar holes in the inner partial application's function type
- Correct closure ABIs / MFunction types result for combinators B/C/T and operator sections
- Monomorphic call args are unaffected — they pass the `containsCEcoMVar` guard and specialize immediately as before
- Simple direct calls and non-nested usage patterns are unaffected

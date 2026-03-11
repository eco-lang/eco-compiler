# Monomorphization Bug Investigation: Missing Occurs Check in Type Substitution

**Date:** 2026-03-11
**Status:** Bug confirmed via instrumentation of self-compilation (Stage 5)

## Summary

The monomorphization type substitution system has a missing occurs check that allows
circular type bindings to form (e.g. `a__callee1 = MTuple [Global, MVar "a__callee1"]`).
These circular bindings cause `resolveMonoVarsHelp` to recurse to extreme depths during
type resolution, leading to OOM crashes. A depth > 200 bail-out currently prevents the
crash but does not fix the root cause.

## Hypothesis

A recursive or heavily-used polymorphic helper over dependency structures
(`Dict (List String) Global Node`, `EverySet (List String) Global`) triggers a cycle
in MVar bindings. The cycle forms because:

1. `normalizeMonoType` only resolves bare MVars, not MVars nested inside complex types
2. `isSelfRef` in `unifyHelp` only catches bare `MVar` self-references
3. `buildRenameMap` reuses counter-suffixed names across calls, causing overwrites

## Instrumentation Approach

Three instrumentation methods were applied by patching the compiled JS (`eco-boot-2.js`)
directly (Elm-level `Debug.log`/`Debug.todo` is stripped by `--optimize`):

### 1. Occurs check at `insertBinding`
Before `Dict.insert`, check if the normalized type contains an MVar with the same name
as the binding target (detecting `a = (Global, a)` style cycles):

```javascript
// In insertBinding (JS-patched eco-boot-2.js, line ~135451)
if (__dbg_hasMVar(name, normalizedTy, 50)) {
    __dbg_occ++;
    console.error("OCCURS_CHECK #" + __dbg_occ + ": \"" + name + "\" self-ref depth=" + __dbg_depth(normalizedTy, 30));
}
```

### 2. Depth monitoring at `insertBinding`
Sample every 100th call and log when `monoTypeStructuralDepth(normalizedTy) > 10`:

```javascript
if (__dbg_total % 100 === 0) {
    var d = __dbg_depth(normalizedTy, 30);
    if (d > 10) { __dbg_deep++; console.error("DEEP_BINDING..."); }
}
```

### 3. Bailout tracking in `resolveMonoVarsHelp`
Log when the depth > 200 bail-out fires, capturing the MonoType discriminant:

```javascript
if (depth > 200) {
    __dbg_bailouts++;
    if (__dbg_bailouts <= 10) console.error("DEPTH_BAILOUT #" + __dbg_bailouts + ": depth=" + depth + " type.$=" + monoType.$);
}
```

## Results

Self-compilation with `--output=bin/eco-boot-debug.mlir` and `--max-old-space-size=8192`:

### Raw debug output

```
Monomorphization started...
  Specialization (worklist)...
FIRST_INSERT_BINDING_CALL: name=a
OCCURS_CHECK #1: "a__callee1" self-ref depth=1
OCCURS_CHECK #2: "a__callee1" self-ref depth=1
OCCURS_CHECK #3: "a__callee1" self-ref depth=2
OCCURS_CHECK #4: "a__callee1" self-ref depth=2
OCCURS_CHECK #5: "a__callee1" self-ref depth=2
OCCURS_CHECK #6: "a__callee1" self-ref depth=2
OCCURS_CHECK #7: "a__callee1" self-ref depth=2
OCCURS_CHECK #8: "a__callee1" self-ref depth=2
OCCURS_CHECK #9: "a__callee1" self-ref depth=1
OCCURS_CHECK #10: "a__callee1" self-ref depth=1
OCCURS_CHECK #11: "a__callee1" self-ref depth=1
OCCURS_CHECK #12: "a__callee1" self-ref depth=2
OCCURS_CHECK #13: "a__callee1" self-ref depth=2
OCCURS_CHECK #14: "a__callee1" self-ref depth=2
OCCURS_CHECK #15: "a__callee1" self-ref depth=2
OCCURS_CHECK #16: "a__callee1" self-ref depth=2
OCCURS_CHECK #17: "a__callee1" self-ref depth=2
OCCURS_CHECK #18: "a__callee1" self-ref depth=1
OCCURS_CHECK #19: "v__callee1" self-ref depth=2
OCCURS_CHECK #20: "v__callee1" self-ref depth=2
DEEP_BINDING #1: "b__callee2" depth=18
DEPTH_BAILOUT #1: depth=201 type.$=9
DEPTH_BAILOUT #2: depth=201 type.$=7
DEPTH_BAILOUT #3: depth=201 type.$=9
DEPTH_BAILOUT #4: depth=201 type.$=7
DEPTH_BAILOUT #5: depth=201 type.$=9
DEPTH_BAILOUT #6: depth=201 type.$=7
DEPTH_BAILOUT #7: depth=201 type.$=9
DEPTH_BAILOUT #8: depth=201 type.$=7
DEPTH_BAILOUT #9: depth=201 type.$=9
DEPTH_BAILOUT #10: depth=201 type.$=7
DEEP_BINDING #2: "a__callee0" depth=11
DEEP_BINDING #3: "b__callee2" depth=18
DEEP_BINDING #4: "a__callee0" depth=11
DEEP_BINDING #5: "b__callee2" depth=17
DEEP_BINDING #6: "w" depth=16
DEEP_BINDING #7: "v" depth=17
DEEP_BINDING #8: "b__callee2" depth=30
DEEP_BINDING #9: "a" depth=16
DEEP_BINDING #10: "b" depth=11
DEEP_BINDING #11: "a" depth=30
DEEP_BINDING #12: "a__callee0" depth=30
DEEP_BINDING #13: "b" depth=30
DEEP_BINDING #14: "b" depth=30
DEEP_BINDING #15: "b__callee2" depth=30
  Type patching + graph assembly...
```

### Without the depth > 200 bail-out (first attempt, 4GB heap)
OOM crash at 4GB:
```
FATAL ERROR: Reached heap limit Allocation failed - JavaScript heap out of memory
```

### Summary statistics

| Metric | Value |
|--------|-------|
| Occurs check violations | 20 |
| Variables with self-references | `a__callee1` (18x), `v__callee1` (2x) |
| Deep bindings (depth > 10) | 15 |
| Max binding depth observed | 30 (capped by sampling depth limit) |
| Depth bailouts at 201 | 10+ |
| Bailout type pattern | Alternating MCustom (`$=9`) and MTuple (`$=7`) |
| Variables reaching depth 30 | `b__callee2`, `a`, `a__callee0`, `b` |

## Root Cause Analysis

Three cooperating defects in `compiler/src/Compiler/Monomorphize/TypeSubst.elm`:

### Defect 1: `normalizeMonoType` only handles bare MVars (line 121)

```elm
normalizeMonoType subst ty =
    case ty of
        Mono.MVar varName _ ->
            -- Path compression for bare MVars
            ...
        _ ->
            ( ty, subst )   -- Complex types pass through unchanged!
```

When `ty` is `MTuple [Global, MVar "a__callee1"]`, the inner `MVar "a__callee1"` is
NOT resolved. The type is stored in the substitution with unresolved inner MVars.

### Defect 2: `isSelfRef` in `unifyHelp` only checks bare MVars (line 218)

```elm
( Can.TVar name, _ ) ->
    let
        isSelfRef =
            case monoType of
                Mono.MVar mName _ ->
                    mName == name   -- Only catches: a = MVar "a"
                _ ->
                    False           -- Misses: a = MTuple [X, MVar "a"]
    in
```

This means `a__callee1 = MTuple [Global, MVar "a__callee1"]` passes the self-reference
check and gets installed as a binding, creating a cycle.

### Defect 3: `buildRenameMap` counter reuse (line 664)

```elm
buildRenameMap callerVarNames funcVarNames acc counter =
    ...
        freshName = name ++ "__callee" ++ String.fromInt counter
    ...
```

The counter starts at 0 each time `unifyFuncCall` is called. Multiple calls to the same
polymorphic function produce the same `__callee0`, `__callee1` names, causing later
bindings to overwrite earlier ones in the shared substitution.

### Chain reaction

1. First call to polymorphic function `f` creates `a__callee1 = MInt`
2. Second call to `f` reuses name `a__callee1` (counter resets to 0)
3. `unifyHelp` processes `(TVar "a__callee1", MTuple [Global, MVar "a__callee1"])`
4. `isSelfRef` returns `False` (it's not a bare MVar)
5. `normalizeMonoType` returns the type unchanged (inner MVars not resolved)
6. `insertBinding` stores `a__callee1 → MTuple [Global, MVar "a__callee1"]`
7. When `resolveMonoVarsHelp` later resolves `a__callee1`, it finds `MTuple [Global, MVar "a__callee1"]`, recurses into the `MVar`, finds the same binding, producing `MTuple [Global, MTuple [Global, MVar "a__callee1"]]`, and so on
8. The alternating MCustom/MTuple pattern at depth 201 confirms right-nested chain growth

## Current Mitigation

The `depth > 200` bail-out in `resolveMonoVarsHelp` (line 511) prevents stack overflow
and OOM. Self-compilation completes successfully with this bail-out in place. However,
the bail-out returns the unresolved type, potentially producing incorrect monomorphized
output.

## Test Coverage Gap

Unit tests in `compiler/tests/SourceIR/PolyChainCases.elm` exercise chained polymorphic
calls (Dict chains, Set operations, graph-like structures) but max out at depth 5.
The bug requires the specific interaction pattern of:
- Multiple calls to the same polymorphic function within one specialization context
- Type variables that appear inside complex types (not bare)
- The `__callee` renaming collision

This interaction only manifests at scale during self-compilation, not in small test cases
with fully concrete argument types.

## Recommended Fix Directions

1. **Proper occurs check in `unifyHelp`**: Replace the bare-MVar `isSelfRef` check with
   `monoTypeContainsMVar name monoType` (already implemented in the codebase, line 468)

2. **Deep `normalizeMonoType`**: Recursively resolve MVars inside complex types, not
   just at the top level

3. **Fresh name generation in `buildRenameMap`**: Use a global counter or include call-site
   context in the suffix to prevent name collisions across multiple `unifyFuncCall` calls

4. **All three fixes together**: The occurs check prevents cycles; deep normalization
   prevents stale MVars; fresh names prevent overwrites. Each addresses a different facet
   of the same underlying problem.

## Files

| File | Role |
|------|------|
| `compiler/src/Compiler/Monomorphize/TypeSubst.elm` | Bug location (all 3 defects) |
| `compiler/src/Compiler/Monomorphize/Specialize.elm` | Caller of `unifyFuncCall` |
| `compiler/build-kernel/bin/eco-boot-2.js` | Instrumented JS (patched) |
| `compiler/build-kernel/bin/eco-boot-2-runner.js` | Runner with debug summary handler |
| `compiler/tests/SourceIR/PolyChainCases.elm` | Test cases (don't reproduce at scale) |

# Root Cause: 9 Remaining Combinator Test Failures

## Traced Example: CombinatorBComposeTest

```elm
k a _ = a                    -- K combinator
s bf uf x = bf x (uf x)      -- S combinator
b = s (k s) k                -- B combinator = composition

inc x = x + 1
square x = x * x

main = Debug.log "result" (b square inc 4)   -- expected: 25
```

**MLIR for `main`** (after CallSegmentationUnknown fixes — `segmentation_unknown` is correctly used):

```mlir
%1 = papCreate(arity=1, function=@b_$_3)       -- b thunk wrapper
%2 = papCreate(arity=1, function=@square_$_1)   -- square
%3 = papCreate(arity=1, function=@inc_$_2)      -- inc
%4 = eco.box 4
%5 = papExtend(%1, %2, %3, %4)                  -- b(square, inc, 4)
     {_call_kind = "segmentation_unknown"}       -- ✓ correct: no remaining_arity
```

The `segmentation_unknown` dispatch is working correctly. At runtime:
1. `eco_apply_segmentation_unknown(b, ..., 3, ...)` — b has arity=1, remaining=1, 3 args ≥ 1
2. → `eco_apply_closure(b, boxed_args, 3)` — over-saturated
3. `eco_closure_call_saturated(b, boxed_args, 1)` — calls `b_$_3(square)` → returns intermediate closure
4. `eco_apply_closure(intermediate, [inc, boxed_4], 2)` — applies remaining args to result

**MLIR for `b_$_3`** — the thunk evaluator for `b = s (k s) k`:

```mlir
func @b_$_3(%arg0: !eco.value) -> !eco.value {
  %0 = papCreate(arity=3, function=@s_$_9)                     -- s (all-!eco.value specialization)
  %2 = papCreate(arity=2, function=@lambda_6$clo, captured=[s]) -- (k s) closure
  %3 = papCreate(arity=2, function=@k_$_8)                      -- k  ← BUG: Int specialization!
  %4 = papExtend(%0, %2, %3, remaining_arity=3)                 -- s((k s), k) → PAP remaining 1
  %5 = papExtend(%4, %arg0, remaining_arity=1)                  -- saturated: calls s_$_9
  return %5
}
```

**MLIR for `s_$_9`** — the all-boxed S combinator:

```mlir
func @s_$_9(%arg0: !eco.value, %arg1: !eco.value, %arg2: !eco.value) -> !eco.value {
  %0 = papExtend(%arg1, %arg2) segmentation_unknown   -- uf(x), i.e. k(square)
  %1 = papExtend(%arg0, %arg2, %0) segmentation_unknown -- bf(x)(uf(x))
  return %1
}
```

**Two specializations of `k` exist:**

| Specialization | Signature | Used for |
|---|---|---|
| `k_$_7` | `(!eco.value, !eco.value) → !eco.value` | All-boxed (closures) |
| `k_$_8` | `(i64, i64) → i64` | Int-specialized |

**The bug:** `b_$_3` creates `k` using `k_$_8` (the Int specialization). But inside `s_$_9`, `k` is called as `k(square)` where `square` is a **closure** (`!eco.value`), not an `i64`.

**The crash sequence:**
1. `s_$_9` calls `k(square)` via `segmentation_unknown`
2. `k` PAP has arity=2, remaining=2. One arg (square) applied → under-saturated
3. `eco_pap_extend` stores `square` (an HPointer to a Closure object) in k's values array with bitmap=0 (boxed)
4. Later, when the second arg arrives and `k_$_8` evaluator runs, the evaluator wrapper reads values from the array
5. `k_$_8` expects `i64` params. The wrapper resolves the HPointer, goes to offset 8, and loads 8 bytes as a raw `i64`
6. But offset 8 of a Closure object is the `packed` field (n_values/max_values/unboxed bitmap), not a valid Int
7. **→ SIGSEGV** (or garbage value, or `Invalid tag after forward resolution` if the loaded value is later used as an HPointer)

## Root Cause

**Wrong monomorphization specialization of `k`** in `b = s (k s) k`.

The monomorphizer picks `k_$_8(i64, i64) → i64` for the second `k` in `s (k s) k`. But inside `s(bf, uf, x) = bf(x)(uf(x))`, `uf` (which is `k`) receives `x` as its first argument. When `b` is used as `b square inc 4`, `x = square` which is a closure — not an Int. The correct specialization is `k_$_7(!eco.value, !eco.value) → !eco.value`.

This is a **pre-existing monomorphization bug**, not caused by `CallSegmentationUnknown`. The `CallSegmentationUnknown` dispatch is working correctly — it properly dispatches to `eco_pap_extend` for under-saturated calls and `eco_apply_closure` for saturated/over-saturated calls. The crash happens downstream when the wrongly-specialized evaluator misinterprets closure values as integers.

---

## All 9 Failing Tests Annotated

All tests share the same root cause pattern: **combinator definitions use polymorphic functions (`k`, `s`) that the monomorphizer specializes for the wrong type context**.

### 1. CombinatorBComposeTest — SIGSEGV
```elm
k a _ = a
s bf uf x = bf x (uf x)
b = s (k s) k                    -- k_$_8(i64,i64) used but receives closures

main = Debug.log "result" (b square inc 4)  -- expected: 25
```
`k` in `b = s (k s) k` receives closures at runtime but is specialized for `i64`. Evaluator wrapper dereferences closure as Int → SIGSEGV.

### 2. CombinatorCFlipTest — SIGSEGV / SIGABRT
```elm
k a _ = a
s bf uf x = bf x (uf x)
b = s (k s) k
c = s (b b s) (k k)              -- Deeper combinator chain: b, s, k all polymorphic
sub x y = x - y

main = Debug.log "result" (c sub 10 3)  -- expected: -7
```
Same pattern but deeper: `c` is built from `b`, `b`, `s`, `k`, `k`. Each combinator application may specialize `k` or `s` for the wrong types. The deeper chain makes it more likely to hit the wrong specialization.

### 3. CombinatorCConsTest — Wrong output: `[1]` instead of `[1,2,3]`
```elm
c = s (b b s) (k k)              -- C combinator (flip)

main = Debug.log "result" (c (::) [2,3] 1)  -- expected: [1,2,3]
```
Same `c` combinator. The wrong specialization causes `k k` to produce a garbage value instead of the correct flip. The cons operation partially succeeds (produces `[1]`) because only the first element is applied correctly.

### 4. CombinatorTThrushTest — SIGSEGV
```elm
c = s (b b s) (k k)
i = s k k                        -- I combinator (identity)
t = c i                          -- T combinator (thrush/pipe)

main = Debug.log "result" (t 7 (\x -> x * 3))  -- expected: 21
```
`t = c i` chains three combinator definitions, each with the same monomorphization specialization bug. `i = s k k` applies `k` in a context where it receives function arguments.

### 5. CombinatorTPipeTest — SIGSEGV
```elm
t = c i                          -- Same T combinator

main = Debug.log "result" (t [1,2,3] (b List.sum (List.map ((*) 2))))  -- expected: 12
```
Same `t` combinator with stdlib functions. The `b List.sum (List.map ...)` chain works (similar to the now-passing CombinatorBSumMapTest), but `t`'s inner `c` and `i` hit the specialization bug.

### 6. CombinatorTest — SIGSEGV
```elm
-- Tests b, c, s, sp, w, t, i all in one file
main =
    Debug.log "b_compose" (b square inc 4)           -- uses b
    Debug.log "c_flip" (c sub 10 3)                  -- uses c
    Debug.log "s_feed" (s (+) double 5)              -- uses s
    Debug.log "sp_combine" (sp mul inc double 6)     -- uses sp
    Debug.log "w_dup" (w mul 9)                      -- uses w
    Debug.log "t_thrush" (t 7 (\x -> x * 3))        -- uses t
    Debug.log "i_identity" (i 42)                    -- uses i
```
First failing call is `b square inc 4` (same as CombinatorBComposeTest). Crashes before reaching subsequent tests.

### 7. CombinatorListStringTest — SIGSEGV
```elm
-- Same combinators with stdlib list/string functions
main =
    Debug.log "b_sum_map" (b List.sum (List.map ((+) 1)) [1,2,3])
    Debug.log "sp_mul" (sp (*) ((+) 1) ((*) 2) 6)
    Debug.log "w_concat" (w (++) "hi")
    Debug.log "c_cons" (c (::) [2,3] 1)              -- c hits specialization bug
    ...
```
`b List.sum ...` and `sp (*)...` pass (similar patterns now fixed). Crashes on `c (::) ...` or subsequent combinator calls that hit the `k` specialization bug.

---

## Summary

| Aspect | Detail |
|---|---|
| **Root cause** | Pre-existing monomorphization bug: `k` in `b = s (k s) k` is specialized as `k_$_8(i64, i64) → i64` but receives closure arguments at runtime |
| **Why it crashes** | Evaluator wrapper for `k_$_8` unboxes closure HPointer as raw i64 → reads invalid memory → SIGSEGV |
| **Is `CallSegmentationUnknown` involved?** | Yes, correctly. The dispatch works. The crash is in the evaluator AFTER dispatch succeeds. |
| **Are these new failures?** | No. All 9 tests fail on unmodified code (verified by reverting the `FromType` change). |
| **What changed?** | The symptom changed from SIGABRT (wrong remaining_arity assertion) to SIGSEGV (correct dispatch, but wrong evaluator types). Previously the staging mismatch crashed first; now the staging is correct but the deeper monomorphization bug is exposed. |
| **Fix location** | Monomorphizer specialization selection — not in `CallSegmentationUnknown` or GlobalOpt. |

---

## Deep Trace: Type Variable Capture in the Monomorphizer

### Test Case

```elm
module CombinatorBComposeTest exposing (main)

k a _ = a                         -- type: a → b → a
s bf uf x = bf x (uf x)          -- type: (a → b → c) → (a → b) → a → c
b = s (k s) k                    -- type: (a → b) → (c → a) → c → b
--      ↑       ↑
--      arg1    arg2 (the second k — the one that gets wrong specialization)

inc x = x + 1                    -- type: Int → Int
square x = x * x                 -- type: Int → Int

main =
    let
        _ = Debug.log "result" (b square inc 4)
        --                      ↑
        --  b : (Int→Int) → (Int→Int) → Int → Int
        --  This concrete type drives the specialization of b's body
    in
    text "done"
```

### Root Cause: Type Variable Capture in `processCallArgs`

The monomorphizer has a **type variable capture bug**: when specializing the body of a polymorphic function, the caller's type substitution leaks into argument specializations, incorrectly resolving the arguments' own type variables.

### Trace Evidence

**Step 1: Building the substitution for `b`'s body**

`specializeNode` (Specialize.elm:700-717) processes `b`'s `Define` node. It unifies `b`'s canonical type with the requested concrete type:

```
b's canonical type:  (a → b) → (c → a) → c → b
requested type:      (Int→Int) → (Int→Int) → Int → Int
```

This produces substitution `subst = { "a" → MInt, "b" → MInt, "c" → MInt }`.

**Step 2: Processing call arguments with the caller's substitution**

`specializeExpr` processes `b`'s body expression `s (k s) k` as a `TOpt.Call` (Specialize.elm:1361). The FIRST thing it does is:

```elm
( processedArgs, argTypes, state1 ) =
    processCallArgs args subst state          -- line 1368-1369
```

This processes `[(k s), k]` using `subst = { "a" → MInt, "b" → MInt, "c" → MInt }`.

**Step 3: The second `k` is specialized with the WRONG substitution**

For the second argument `k` (a `VarGlobal`), `processCallArg` (Specialize.elm:2582-2606) does:

```elm
canType = meta.tipe                    -- k's canonical type: a → b → a
monoType = applySubst mvarEnv subst canType   -- line 2590
```

`applySubst` (TypeSubst.elm:661-664) looks up each `TVar` by **string name** in `subst`:

```elm
Can.TVar name ->
    case Dict.get name subst of       -- line 662
        Just monoType -> ( resolveMonoVars env subst monoType, env )
```

- `k`'s type variable `"a"` → `Dict.get "a" subst` → `Just MInt` ← **CAPTURED!**
- `k`'s type variable `"b"` → `Dict.get "b" subst` → `Just MInt` ← **CAPTURED!**

Result: `k`'s type resolves to `MInt → MInt → MInt`.

Since `containsCEcoMVar(MInt → MInt → MInt)` = False (line 2592), the argument is immediately specialized:

```elm
( monoExpr, st1 ) = specializeExpr arg subst st   -- line 2600-2601
```

This calls `enqueueSpec k (MInt → MInt → MInt)` → creates specialization `k_$_8(i64, i64) → i64`.

**Step 4: Callee renaming happens TOO LATE**

Only AFTER `processCallArgs` returns does the code rename `s`'s type variables (line 1394):

```elm
unifyResult = unifyCallSiteWithRenaming ... funcCanType argTypes canType subst epoch schemeInfo
```

This renaming avoids collision between `s`'s own type variables and `b`'s substitution keys. But by this point, the arguments have already been specialized with the wrong types.

### What Should Happen

In the expression `s (k s) k`:
- `s` has type `(a → b → c) → (a → b) → a → c`
- The second `k` is `s`'s second parameter `uf : (a → b)`, where `a` and `b` are `s`'s type variables
- When `b` is specialized for `(Int→Int) → (Int→Int) → Int → Int`:
  - `s`'s `a` should resolve to something like `Int→Int` (the type of `square`)
  - `s`'s `b` should resolve to something like `Int→Int`
  - So `uf = k` should have type `(Int→Int) → (Int→Int)` i.e. `k_$_7(!eco.value, !eco.value) → !eco.value`
- But the variable capture resolves `k`'s own `a, b` to `MInt` instead

### Impact

| What happens | Expected | Actual |
|---|---|---|
| Second `k` in `s (k s) k` | `k_$_7(!eco.value, !eco.value) → !eco.value` | `k_$_8(i64, i64) → i64` |
| `s_$_9` calls `k(square)` | Stores closure as `!eco.value` | Stores closure as `!eco.value` but evaluator expects `i64` |
| Evaluator unboxes captured value | Reads `!eco.value` (passthrough) | Reads offset 8 of closure object as raw `i64` → **SIGSEGV** |

### Why This Affects All 7 Combinator Tests

Every combinator definition uses the pattern `s <arg1> <arg2>` (or nested compositions thereof). When the combinator's outer type variables happen to share names with the arguments' type variables (which is the default in Elm since `a, b, c, ...` are reused), the caller's substitution captures the arguments' variables.

| Test | Combinator | Captured variable |
|---|---|---|
| CombinatorBComposeTest | `b = s (k s) k` | `k`'s `a,b` captured by `b`'s `a,b` |
| CombinatorCFlipTest | `c = s (b b s) (k k)` | `k`'s variables captured |
| CombinatorCConsTest | Same `c` | Same capture |
| CombinatorTThrushTest | `t = c i`, `i = s k k` | `k`'s variables captured in `i`'s context |
| CombinatorTPipeTest | Same `t` | Same |
| CombinatorTest | All combinators | Multiple captures |
| CombinatorListStringTest | Same combinators | Same captures |

### The Variable Capture Mechanism in Detail

In Elm's canonical AST, type variables are identified by **string names**. The function `k a _ = a` has canonical type using variables literally named `"a"` and `"b"`. The combinator `b` has type `(a → b) → (c → a) → c → b` using variables `"a"`, `"b"`, `"c"`.

The substitution built when specializing `b`'s body maps `{"a" → MInt, "b" → MInt, "c" → MInt}`. When this substitution is applied to `k`'s canonical type `a → b → a`, the shared names `"a"` and `"b"` cause `k` to be resolved as `MInt → MInt → MInt` — even though `k`'s `a` and `b` are independent type variables that should be resolved by `s`'s call-site unification, not by `b`'s outer context.

The `unifyCallSiteWithRenaming` function (Specialize.elm:192-257) exists specifically to α-rename the callee's type variables and avoid this collision. But it runs AFTER `processCallArgs` has already specialized the arguments. The renaming protects `s`'s own type resolution but does NOT protect the arguments passed to `s`.

### Fix Location

The bug is in `processCallArgs` (Specialize.elm:2582-2606). The fix needs to either:
1. **Defer argument specialization** until after `unifyCallSiteWithRenaming` determines the correct types for each parameter position
2. **α-rename** argument canonical types before applying the caller's substitution (removing shared variable names)
3. **Filter the substitution** when specializing arguments, excluding variables that belong to the caller's scope but not the argument's scope

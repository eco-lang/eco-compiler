# Bug: `let`-bound `number` mis-specialized to `Int` in a `Float` context

**Component:** Compiler — monomorphizer (`Compiler.Monomorphize.Specialize`)
**Surfaces in:** native / AOT backend (`eco make … --output=<elf>` and `--output=*.mlir`)
**Severity:** High. Manifests as a hard compiler crash in the common case, **and as a silent miscompilation (wrong runtime results) in the boxed case** — the latter is the more dangerous outcome.
**Status:** Root cause identified; not fixed. Regression tests added (see end).

---

## 1. Summary

A `let`-bound, unannotated numeric value (type `number`) that is used as an operand
of a `Float` operation is monomorphized to `Int` instead of `Float`. The numeric
literal is lowered to an `i64` constant while the operator instance is independently
specialized to `Float`. The resulting `i64`-into-`Float` mismatch then surfaces
either as an MLIR codegen crash, a native-lowering verifier error, or — when the
value is laundered through a box — a silently wrong runtime result.

The mistype is in **monomorphization**: a generalized `number` `let` binding is
defaulted to `Int` *before* its use sites are consulted. The same value at **top
level** is specialized correctly, and the codegen faithfully lowers whatever
(wrong) MonoType it is given.

---

## 2. How it was discovered

Compiling the `elm-oo-style` example to a native binary:

```
$ eco make src/elm/Main.elm --output=test
Success! Compiled 12 modules.
Eco crash: Kernel signature mismatch for Elm_Kernel_Basics_mul_Float:
    existing (f64, f64 -> f64) vs new (f64, i64 -> f64)
```

It also reproduces with `--output=/tmp/out.mlir`, which proves the fault is in the
**Elm→MLIR codegen front-end**, not in LLVM lowering. (The `--output=…html`/`.js`
JS path is unaffected — it uses a different backend.)

The crash originates in `Compiler/Generate/MLIR/Context.elm`, `insertKernelDecl`
(~line 606, invariant CGEN_038): the same kernel symbol is registered twice with
conflicting ABIs.

---

## 3. Minimal reproduction

```elm
compute = let n = 30 in 1.4 * n      -- CRASHES (mul_Float (f64, i64))
```

Controls that pin the trigger:

| Program | Result | Why |
|---|---|---|
| `let n = 30 in 1.4 * n` | **crash** | bare `number` `let`, defaulted to `Int` |
| `1.4 * 30` (inline literal) | **OK** | the literal unifies to `Float` at its single use |
| `let n = 30.0 in 1.4 * n` | **OK** | `n` annotated/inferred `Float` |
| `let z = 10 + 20 in z * 1.5` | **crash** | not literal-specific — any `number`-typed `let` |
| top-level `n = 30 ; 1.4 * n` | **OK** | top-level specialization is use-site driven |

The original real-world site is `Config.elm`:

```elm
config =
    let
        fontSize = 30          -- number
        lineHeightRatio = 1.4  -- Float
    in
    { fontSize = fontSize
    , lineHeight = (lineHeightRatio * fontSize) |> floor |> toFloat   -- crash here
    , ... }
```

---

## 4. Full trace evidence

### 4.1 The conflicting MLIR (instrumented dump)

`insertKernelDecl` was temporarily changed to log-and-continue instead of `crash`,
so the full MLIR was emitted, then dumped to text with `ecoc <file> --emit=mlir`.
The offending calls (enclosing `func.func` shown via `awk`):

```mlir
// in @Config_config
%0 = "eco.call"(%cst, %c30_i64) <{callee = @Elm_Kernel_Basics_mul_Float}>
        {_operand_types = [f64, i64]} : (f64, i64) -> f64
// in @Scene_Root_background
%10 = "eco.call"(%c20_i64, %8) <{callee = @Elm_Kernel_Basics_mul_Float}>
        {_operand_types = [i64, f64]} : (i64, f64) -> f64
```

The bad operand is a **literal integer constant** (`%c30_i64`, `%c20_i64`) — i.e. a
numeric literal that was given MonoType `Int` and lowered to an `i64` constant,
even though the multiply is `mul_Float`. Two trace lines were emitted (both
operand orders):

```
[TRACE mismatch] Kernel signature mismatch for Elm_Kernel_Basics_mul_Float:
    existing (f64, f64 -> f64) vs new (f64, i64 -> f64)
[TRACE mismatch] Kernel signature mismatch for Elm_Kernel_Basics_mul_Float:
    existing (f64, f64 -> f64) vs new (i64, f64 -> f64)
```

For contrast, the **correct** top-level case (`n = 30` used at `Float`) lowers to:

```mlir
func.func private @T1_n_$_5() -> f64 { %cst = arith.constant 3.000000e+01 : f64 ... }
%1 = eco.float.mul %cst, %0 {_operand_types = [f64, f64]} : f64   // intrinsic, no kernel call
```

i.e. `n` is correctly specialized to `Float` (`3.0e+01 : f64`).

### 4.2 The monomorphizer path (root cause)

`TOpt.Let` dispatch in `Compiler/Monomorphize/Specialize.elm`:

1. `Can.TLambda _ _` → `localMulti` demand-driven path (function lets) — **use-site aware**.
2. else if `shouldUseValueMulti` → `valueMulti` demand-driven path — **use-site aware**.
3. else → **eager path** (line ~2731) — **NOT use-site aware**.

The gate (line ~416):

```elm
shouldUseValueMulti mvarEnv defCanType =
    typeContainsLambda defCanType && hasCEcoTVar mvarEnv defCanType
```

A bare `number` fails **both** conjuncts: it contains no lambda, and `hasCEcoTVar`
explicitly excludes number vars (`not (State.isNumberVar mvarId mvarEnv)`, ~line 408).
So `let n = 30` takes the **eager path**, which commits to a single type up front:

```elm
defMonoType0 = Mono.forceCNumberToInt (applySubstFV state subst defCanType)
```

`forceCNumberToInt` turns the unresolved `number` into a concrete `MInt`. Because
`MInt` contains no MVar, the `useExprType` fallback does not fire, so `n` is bound
in `varEnv` as `Int`. The `(*)` at the use site is specialized to `Float`
independently (its `meta.tipe` was unified to `Float -> Float -> Float`). The two
disagree.

By contrast, a **top-level** reference (`TOpt.VarGlobal`, ~line 1707) computes its
type from the **use-site** `meta.tipe` and `enqueueSpec`s a fresh specialization per
requested type — so `n` gets a `Float` instance there.

### 4.3 Why it becomes a kernel-signature crash (codegen)

* A direct `Float * Float` is intrinsic-lowered to `eco.float.mul` and never touches
  the kernel symbol.
* `mul` with actual arg types `[MFloat, MInt]` **misses** the intrinsic
  (`Intrinsics.kernelIntrinsic` only matches `[MFloat,MFloat]`/`[MInt,MInt]`), so it
  takes the kernel path (`Expr.elm` `MonoVarKernel … ElmDerived`, ~line 3360).
* There, `registerKernelInstance` records `mul_Float` as `(f64, f64)` (from the
  operator's funcType), then `boxToMatchSignatureTyped` (`Expr.elm:1228`) **punts** on
  the i64-vs-f64 case:

  ```elm
  -- No boxing solution (e.g. i64 vs f64) - use actual type for now
  ( opsAcc, ( var, actualTy ) :: pairsAcc, ctxAcc )
  ```

  so the i64 operand is kept, and `Ops.ecoCallNamed → registerKernelCall`
  (`Ops.elm:481`) re-registers the **same** symbol as `(f64, i64)`.
* `insertKernelDecl` (`Context.elm:606`) sees the conflict and crashes (CGEN_038).

The conflict is **intra-call-site** (one bad `*` produces both registrations).

---

## 5. Manifestations (all the same root cause)

Confirmed by probing (compile + run each):

| Routing of the `number` use | Outcome |
|---|---|
| direct → typed Float kernel (`mul`,`sqrt`,`+`,`/`,`^`) | **kernel-signature crash** |
| laundered through `identity` | invalid MLIR: `'eco.float.mul' operand #0 must be 64-bit float, but got 'i64'` |
| Float seed of `List.foldl (+)` | invalid MLIR: `'llvm.call' operand type mismatch … 'i64' != 'f64'` |
| boxed in tuple / record / list / `Maybe`, then used at Float | **SILENT WRONG runtime result** |

The silent case is the dangerous one. Native runs (expected `45` / `[45,60]`):

```
let p = (30,99)  in Tuple.first p * 1.5            -> 0      (expected 45)
let r = {a=30}   in r.a * 1.5                       -> 0      (expected 45)
let xs = [30,40] in List.map (\x -> x*1.5) xs       -> [0, 0] (expected [45,60])
let m = Just 30  in Maybe.map (\x -> x*1.5) m       -> 0      (expected 45)
```

The `i64` bit-pattern of the literal is boxed, then reinterpreted as an `f64`
(a denormal ≈ 0) when the consumer unboxes it as a `Float` — hence `0`. No compiler
diagnostic is produced.

---

## 6. Scope / boundary

* **Affected:** any non-function `let` whose generalized type is (or contains) an
  unresolved `number` used at `Float` (or any non-default numeric type).
* **Not affected (controls confirmed OK):** top-level `number` values; boxed
  polymorphism over plain type variables (`let e = [] in (1::e, "a"::e)`,
  `Maybe a` used at `Int`+`String`); lambda-carrying lets (handled by
  `valueMulti`/`localMulti`). The gap is specifically the **unboxed-representation**
  constrained variable `number` (`Int`=i64 vs `Float`=f64).

---

## 7. Suggested fix direction

Route non-function `let` bindings whose type carries an unresolved `CNumber`
through the existing demand-driven `valueMulti` machinery (e.g. relax
`shouldUseValueMulti` to also fire on unresolved number vars) so use-site numeric
types drive specialization *before* `forceCNumberToInt` defaults them. The
`valueMulti` path already records plain `VarLocal` references as instances
(`getValueMultiVar`), so the plumbing exists.

The codegen punt at `Expr.elm:1228` ("use actual type for now") and the dual
registration via `ecoCallNamed` (`Ops.elm:481`) are secondary; the primary fix is
in the monomorphizer.

---

## 8. Regression tests added

`test/elm/src/`:

* `LetNumberFloatMulTest.elm` — `mul` crash (`a:42 b:42 c:45`); `c` is the
  `let z = 10 + 20` expression variant.
* `LetNumberFloatArithCrashTest.elm` — `sqrt` / `+` / `/` / `^` crashes.
* `LetNumberIndirectMisspecTest.elm` — dual-use, `identity`-laundered, `foldl` seed,
  top-level-fn applied, closure capture.
* `LetNumberBoxedSilentMiscompileTest.elm` — tuple/record/list/`Maybe`/nested-record
  (the **silent** variant; currently all print `0`).

All fail with the current compiler and will pass once the monomorphizer specializes
the binding to the numeric type its use sites demand.

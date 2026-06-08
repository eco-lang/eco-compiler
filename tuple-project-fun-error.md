# Bug: tuple-projected function applied to a primitive — `papExtend` operand #0 typed as the call result

**Component:** Compiler — monomorphizer path typing (`Compiler.Monomorphize.Specialize` / `GlobalOpt.MonoInlineSimplify`), surfaced via MLIR codegen (`Compiler.Generate.MLIR.Patterns`)
**Surfaces in:** native / AOT backend (invalid MLIR rejected at native lowering)
**Severity:** High. Produces invalid MLIR (build failure) for ordinary, well-typed code.
**Status:** Root cause behaviorally proven; codegen consumption line pinned; exact monomorphizer write-site localized (not line-pinned). Not fixed. Regression test added (see end).

This is a **separate** bug from the `let`-`number` mis-specialization
(`let-number-misspec-error.md`). It involves no `number` defaulting, no
polymorphism, and no `let` — it reproduces with fully monomorphic closures at top
level. The two share only a *shape*: a wrong `MonoType` produced by the
monomorphizer that codegen faithfully lowers into an invalid op.

---

## 1. Summary

When a `Tuple.first` / `Tuple.second` projection is used **directly as the function
of a saturated application** whose result is an unboxed primitive (`Int`/`Float`/
`Char`), the projected closure operand is typed as `monoTypeToAbi(application
result type)` — i.e. `i64`/`f64` — instead of `eco.value`. The `eco.papExtend` op
requires its closure operand (`#0`) to be a boxed `eco.value`, so the IR fails
verification during native lowering:

```
error: 'eco.papExtend' op operand #0 must be eco.value, but got 'i64'
```

When the application's result is a *boxed* type (`List`, `String`, or an
under-saturated PAP), `monoTypeToAbi` happens to yield `eco.value`, so the same
code compiles and runs correctly — masking the bug.

---

## 2. How it was discovered

While probing polymorphism for mis-specialization beyond `number`:

```elm
fns = ( \x -> x, \y -> y )
main = let _ = Debug.log "OUT" ( Tuple.first fns 1, Tuple.second fns "ab" ) in text "done"
```

```
-- NATIVE LOWERING ERROR -------------------------------------------------------
error: 'eco.papExtend' op operand #0 must be eco.value, but got 'i64'
```

The front-end emits MLIR successfully; the error is raised when `eco-boot-native`
lowers it (verifier on the eco dialect). `--output=*.mlir` therefore *succeeds*
(bytecode is written), while `--output=<elf>` fails.

---

## 3. Minimal reproduction

```elm
fns : ( Int -> Int, Int -> Int )
fns = ( \x -> x + 1, \y -> y + 2 )
main = let _ = Debug.log "a" (Tuple.first fns 1) in text "done"   -- FAILS
```

Fully monomorphic, top level, no `let`, no `number` ambiguity.

---

## 4. Full trace evidence

### 4.1 The op constraint (`runtime/src/codegen/Ops.td`, `Eco_PapExtendOp`)

```tablegen
let arguments = (ins
    Eco_Value:$closure,                 // operand #0 — MUST be eco.value (boxed)
    Variadic<Eco_AnyValue>:$newargs,    // operands #1+ — primitives ALLOWED (i64/f64/i16),
    ...);                               //                kinds tracked by newargs_unboxed_bitmap
```

So an unboxed **argument** is legal here (this is the generic/segmentation-unknown
apply ABI). The verifier complaint is about **operand #0 — the closure** — meaning
the projected closure value itself is typed `i64`.

### 4.2 The valid sibling (boxed argument), shows the lowering shape

`Tuple.first fns "a"` (closures used at `String`) is *valid*; `ecoc --emit=mlir`
dumps:

```mlir
%1 = "eco.call"() <{callee = @R2_fns_$_1}> : () -> !eco.value           // the tuple
%2 = eco.project.tuple2 %1[0] : !eco.value -> !eco.value                // Tuple.first → closure
%4 = "eco.papExtend"(%2, %3)                                            // operand #0 = %2 (eco.value) ✓
        {_call_kind = "segmentation_unknown"} : (!eco.value, !eco.value) -> !eco.value
```

So `Tuple.first fns` lowers to `eco.project.tuple2`, whose **result type** feeds
`papExtend` operand #0. The question is therefore: why is that projection `i64` in
the failing cases?

(The `--text-mlir` flag is broken in this build — `writeMonoMlirStreaming` aborts
with "bad file descriptor"/"file not found" — and `ecoc` verifies on parse, so the
*invalid* IR could not be dumped directly. The result type was instead established
by discriminating experiments.)

### 4.3 Discriminating experiments

Varying the closure / application result type, holding the structure fixed
(`fns = (\…, \…)` ; `Tuple.first fns <arg>`):

| Program | application result type | operand #0 type | outcome |
|---|---|---|---|
| `\x -> x + 1` , `Tuple.first fns 1` | `Int` | `i64` | **fail** |
| `\x -> toFloat x + 0.5` , `… fns 1` | `Float` | `f64` | **fail** (`got 'f64'`) |
| `\x -> [x]` , `… fns 1` | `List Int` | `eco.value` | **OK** → `([1],[2])` |
| `\x -> String.fromInt x` , `… fns 1` | `String` | `eco.value` | **OK** → `("1","2")` |
| `… fns "a"` (closures `\x->x`) | `String` | `eco.value` | **OK** → `("a","b")` |

The clincher — a **2-argument** closure, distinguishing "result type" from
"closure's own type" and from "tuple element type":

| Program | first application result | outcome |
|---|---|---|
| `fns = (\x y -> x+y, …)` ; `Tuple.first fns 1 2` (saturated) | `Int` | **fail** (`i64`) |
| `fns = (\x y -> x+y, …)` ; `let g = Tuple.first fns 1 in g 2` (under-saturated) | `Int -> Int` | **OK** → `3` |

`let g = …` works because the first application is *under-saturated* (its result is
`Int -> Int`, boxed), so operand #0 is `eco.value`; binding to `g` then breaks the
chain. The saturated one-expression form fails. This rules out **tuple-element-type
collapse** (the element type is identical in both, so that theory would break the
working `let` case too).

**Conclusion from the data:** operand #0 (the projected closure) is typed
`monoTypeToAbi(the application's result type)`:

* result `Int` → `i64` (fail), `Float` → `f64` (fail)
* result `List`/`String`/PAP → `eco.value` (works)

### 4.4 Where the wrong type is consumed (codegen)

`Compiler/Generate/MLIR/Patterns.elm` (~line 345, `Tuple2Container`):

```elm
fieldAbiType = Types.monoTypeToAbi resultType
... if Types.isUnboxable fieldAbiType then  -- i64/f64/i16 → project as primitive
        Ops.ecoProjectTuple2 ctx primitiveVar index fieldAbiType subVar
    else                                     -- eco.value → project boxed
        Ops.ecoProjectTuple2 ctx valVar index Types.ecoValue subVar
```

`resultType` here is `Mono.MonoIndex.resultType` from the projection path. When it
is a primitive, the projection (and hence `papExtend` operand #0) is typed `i64`/
`f64`. `eco.project.tuple2` itself accepts that, but `papExtend`'s `Eco_Value`
operand-#0 constraint rejects it downstream.

### 4.5 Where the wrong type originates (monomorphizer)

`MonoIndex.resultType` is built in `Compiler/Monomorphize/Specialize.elm`,
`specializePath` (~line 3914):

```elm
resultType = computeIndexProjectionType mvarEnv globalTypeEnv hint index containerType
-- HintTuple2 → computeTupleElementType index containerType   (~line 4033)
```

`computeTupleElementType` *correctly* reads the element type out of the container's
`MTuple`. Since the working `let` case (4.3) shows the element type is **not**
collapsed, the wrong `i64`/`f64` must be the **application result type** ending up
on the inlined projection's `MonoIndex.resultType` — written when `Tuple.first` is
inlined as the function of the application (`Compiler/GlobalOpt/MonoInlineSimplify.elm`,
which rewrites/threads `MonoIndex` nodes, e.g. ~lines 1471 / 2541).

**Same shape as the `let`-`number` bug:** the monomorphizer attaches a wrong
`MonoType` (here, the call result type on the projected-function operand); codegen
faithfully lowers it into an invalid op.

---

## 5. Scope / boundary (all confirmed)

* **Fails:** `Tuple.first`/`Tuple.second` used *directly as the function* of a
  saturated application returning an unboxed primitive (`Int`/`Float`/`Char`).
  Reproduces monomorphic, at top level, with 1- and 2-arg closures.
* **Works:** boxed result (`List`/`String`/under-saturated PAP); the function reached
  via a **record field** (`let r = {f = \x -> x} in r.f 1`), a **bare `let`**
  (`let f = \x -> x in f 1`), or a **let-bound projection**
  (`let g = Tuple.first fns 1 in g 2`).

---

## 6. Suggested fix direction

The projected-function operand of an application must be typed `eco.value` (the
function's ABI), independent of the application's result type. Either:

* fix the monomorphizer so the inlined `Tuple.first`/`Tuple.second` projection's
  `MonoIndex.resultType` is the **tuple element (function) type**, not the call
  result type; and/or
* make the apply path force operand #0 to `eco.value` (box/keep boxed) when the
  function subexpression is a projection, mirroring what record-field and
  let-bound functions already do.

The exact monomorphizer write-site (the line in `MonoInlineSimplify` that puts the
call result type onto the inlined projection node) still needs a one-shot
`Mono.typeOf` dump to line-pin; everything upstream of it is established by the
experiments above.

---

## 7. Regression test added

`test/elm/src/TupleProjectedClosureApplyTest.elm` — top-level monomorphic
`fns : (Int -> Int, Int -> Int)`, `Tuple.first fns 1` / `Tuple.second fns 2`
(`CHECK a:2 b:4`) plus a `Float`-argument case (`f:5`). Fails to build with the
current compiler; passes once the projected function operand is typed `eco.value`.

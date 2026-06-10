# Bug analysis: `specializePath: Expected MRecord ... got MTuple` (3-tuple outgoing ports)

**Status:** root-caused, fixed, regression test added.
**Date:** 2026-06-10
**Crash:** `Eco crash: Specialize.specializePath: Expected MRecord for field path but got: MTuple ...`

---

## 1. Summary

A `port module` that declares an **outgoing port whose payload is a 3-element
tuple** and uses it (reachable from `main`) crashes the compiler during
monomorphization:

```
Eco crash: Specialize.specializePath: Expected MRecord for field path but got: MTuple ...
```

The crash is a **record/tuple confusion in the typed port-encoder generator**.
When the compiler synthesizes the JSON encoder for an outgoing port, the
encoder for tuple elements *beyond the second* projects the tuple with a
**record field access `Field "cs"`** instead of a positional tuple `Index`.
The MLIR/typed backend represents tuples as positional `MTuple` values, so when
monomorphization walks that destructor path it finds the root is an `MTuple`
where the `Field` projection demands an `MRecord`, and crashes.

* **Origin found:** `compiler/src/Compiler/LocalOpt/Typed/Port.elm` — `encodeTuple` / `letCs_`.
* **Crash site:** `compiler/src/Compiler/Monomorphize/Specialize.elm` — `specializePath`, `TOpt.Field` case.
* **Fix:** make `letCs_` emit a positional tuple `Index` (`HintTuple3`) instead of `ArrayIndex (Field "cs" …)`.

---

## 2. Reproduction

The user's original command pointed at a non-existent file; the real entry
point is `Top.elm`, and the native/monomorphization pipeline is engaged by an
`.mlir` (non-JS) output target:

```bash
cd projects/elm-aws-codegen/
/work/build/compiler/build-kernel/bin/eco make src/elm/Top.elm --output=test.mlir
# => Eco crash: Specialize.specializePath: Expected MRecord for field path but got: MTuple ...
```

`Top.elm` declares:

```elm
port codeOutPort : ( String, String, List String ) -> Cmd msg
```

and uses it:

```elm
( Case.toCamelCaseUpper service.metaData.serviceId ++ ".elm"
, outputString
, []
)
    |> codeOutPort
```

### Minimal reproducer (12 lines)

```elm
port module Main exposing (main)
import Platform
port out3 : ( String, String, List String ) -> Cmd msg
main : Program () () msg
main =
    Platform.worker
        { init = \_ -> ( (), out3 ( "x", "y", [ "z" ] ) )
        , update = \_ model -> ( model, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
```

### Boundary (proves the trigger is exactly a 3-tuple)

| Port payload                          | Result    |
|---------------------------------------|-----------|
| `( String, String )` (2-tuple)        | ✅ compiles |
| `( String, String, List String )`     | ❌ crash    |
| `( Int, Int, Int )`                   | ❌ crash    |

A 2-tuple port compiles; any 3-tuple port crashes, regardless of element types.

---

## 3. Trace evidence

`specializePath`'s `Field` crash was instrumented to print the field name, the
full (non-truncated) container `MonoType`, the destructor name, the
specialization being processed, and both the typed-optimized path and the
already-specialized sub-path. Running the instrumented compiler on `Top.elm`:

```
Error: Specialize.specializePath: Expected MRecord for field path but got: MTuple ...
  [TRACE] field          = 'cs'
  [TRACE] recordType(full)= MTuple[MString, MString, MList(MString)]
  [TRACE] destructorName  = 'c'
  [TRACE] currentGlobal   = Top.codeOutPort
  [TRACE] toptPath        = Field(cs) -> Root($)
  [TRACE] monoSubPath     = MonoRoot($ : MTuple[MString, MString, MList(MString)])
```

On the minimal reproducer (identical, with `Main.out3`):

```
  [TRACE] field          = 'cs'
  [TRACE] recordType(full)= MTuple[MString, MString, MList(MString)]
  [TRACE] destructorName  = 'c'
  [TRACE] currentGlobal   = Main.out3
  [TRACE] toptPath        = Field(cs) -> Root($)
```

Reading the trace:

* `currentGlobal = …out3` / `…codeOutPort` — the crash happens while monomorphizing the **outgoing port** itself.
* `monoSubPath = MonoRoot($ : MTuple[MString, MString, MList(MString)])` — the scrutinee root `$` is the port's tuple argument; its monomorphized type is exactly the declared 3-tuple `(String, String, List String)`.
* `toptPath = Field(cs) -> Root($)` — the destructor projects the root with a **record field access named `cs`**.
* `field = 'cs'` on a value typed `MTuple[...]` → record-access-on-a-tuple → crash.

The `'cs'` is a **literal** field name emitted by the compiler (not from user
source and not an `--optimize` field-rename — it is the same under any options).

---

## 4. Root cause

`compiler/src/Compiler/LocalOpt/Typed/Port.elm`, `encodeTuple`. Elm tuples are
represented in canonical types as `Can.TTuple a b cs`, where `a`/`b` are the
first two element types and `cs` is the **list of remaining element types**
(empty for a Tuple2, one element for a Tuple3 — Elm has no Tuple4+).

The encoder destructures `$` (the tuple) element by element. It uses two
helpers:

```elm
-- correct: positional tuple projection for elements 0 and 1
let_ arg argType index body =
    TOpt.Destruct (TOpt.Destructor arg (TOpt.Index index hint (TOpt.Root Name.dollar)) …) body …

-- BUG: record field access for elements beyond the second
letCs_ arg argType index body =
    TOpt.Destruct (TOpt.Destructor arg (TOpt.ArrayIndex index (TOpt.Field "cs" (TOpt.Root Name.dollar))) …) body …
```

For a Tuple3 the encoder emits:

* element 0 → `let_ "a" … Index.first`  → `Index(0, HintTuple3) -> Root $`  ✅
* element 1 → `let_ "b" … Index.second` → `Index(1, HintTuple3) -> Root $`  ✅
* element 2 → `letCs_ "c" … 0`          → `ArrayIndex(0, Field("cs", Root $))` ❌

`IndexName.fromIndex Index.third == "c"`, which is exactly the
`destructorName = 'c'` in the trace.

`Field "cs"` is the **erased JavaScript-runtime tuple layout** copied verbatim
into the typed path: `compiler/src/Compiler/LocalOpt/Erased/Port.elm:197-199`
contains the byte-identical

```elm
Opt.Destruct (Opt.Destructor arg (Opt.ArrayIndex index (Opt.Field "cs" (Opt.Root Name.dollar)))) body
```

The typed/MLIR backend, however, represents tuples as **positional `MTuple`
values** projected with `TOpt.Index` (see `MONO_006`, `REP_HEAP_001`,
`Specialize.computeTupleElementType`). A record `Field` projection against an
`MTuple` is therefore meaningless, and `specializePath` (which recomputes the
monomorphic type at each path step) rejects it:

```elm
-- Compiler/Monomorphize/Specialize.elm, specializePath, TOpt.Field case
case recordType of
    Mono.MRecord fields -> …
    _ -> Utils.Crash.crash ("…Expected MRecord for field path but got: " ++ …)
```

### Why it only fires for 3-tuples

`letCs_` is only invoked for the elements in `cs`. For a Tuple2, `cs == []`, so
`letCs_` never runs and the encoder is correct. For a Tuple3, `cs == [c]`, so
`letCs_` runs once and emits the broken path. This matches the boundary table
in §2 exactly.

---

## 5. The fix

`compiler/src/Compiler/LocalOpt/Typed/Port.elm`. Make `letCs_` project the
tuple positionally, using the element's logical tuple index (`Index.third`
for the single Tuple3 tail element) and `HintTuple3`:

```elm
letCs_ : Name -> Can.Type Name -> Index.ZeroBased -> TOpt.Expr Name -> TOpt.Expr Name
letCs_ arg argType index body =
    TOpt.Destruct (TOpt.Destructor arg (TOpt.Index index TOpt.HintTuple3 (TOpt.Root Name.dollar)) { tipe = argType, tvar = Nothing }) body { tipe = TOpt.typeOf body, tvar = Nothing }
```

and pass the logical `index` (a `Index.ZeroBased`) instead of the array index `i`
at the call site:

```elm
(List.foldr (\( _, index, argType ) -> letCs_ (IndexName.fromIndex index) argType index)
    …
    indexedCs
)
```

`cs` is non-empty only for a Tuple3, so the container hint is always
`HintTuple3` and `index` is always `Index.third`; the generic fold is retained
for clarity/symmetry with `let_`.

---

## 6. Verification

Using the rebuilt compiler (this fix; `Specialize.elm` instrumentation
reverted):

| Case                                                | Before fix | After fix |
|-----------------------------------------------------|------------|-----------|
| Minimal `out3 : (String,String,List String)` port   | crash      | ✅ compiles |
| `(Int,Int,Int)` port                                | crash      | ✅ compiles |
| 2-tuple port (control)                              | ✅          | ✅          |
| `projects/elm-aws-codegen/src/elm/Top.elm`          | crash      | past the crash (frontend + monomorphization proceed) |

End-to-end on the minimal program:

```
compile  src/OutgoingPortTuple3Test.elm  → MLIR        : Success
lower    t.mlir → native ELF (eco-boot-native)         : ok
run      ./t_bin                                       : exit 0, prints
         OutgoingPortTuple3Test: "sent"
```

The outgoing port is effectively a no-op in the native runtime today (the
encoded value is produced but not dispatched anywhere), so a `Platform.worker`
that fires it and then returns `Cmd.none` terminates cleanly — making it a
viable AOT E2E test.

---

## 7. Regression test

Added `test/elm/src/OutgoingPortTuple3Test.elm` (AOT E2E suite — compiled,
lowered, run, and checked against `-- CHECK:` stdout):

```elm
port module OutgoingPortTuple3Test exposing (main)

-- CHECK: OutgoingPortTuple3Test: "sent"

import Platform

port out3 : ( String, String, List String ) -> Cmd msg

init : () -> ( (), Cmd msg )
init _ =
    let
        _ = Debug.log "OutgoingPortTuple3Test" "sent"
    in
    ( (), out3 ( "name.elm", "body", [ "x", "y" ] ) )

main : Program () () msg
main =
    Platform.worker
        { init = init
        , update = \_ model -> ( model, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
```

Before the fix this fails to compile (the monomorphization crash); after the
fix it builds and prints the CHECK line.

---

## 8. Related observation (out of scope for the crash)

The erased JavaScript path (`compiler/src/Compiler/LocalOpt/Erased/Port.elm:197-199`)
contains the **identical** `ArrayIndex index (Field "cs" (Root $))` projection.
The eco JS tuple representation is `{$:'#3', a, b, c}` (see
`elm.js:_Utils_Tuple3`) — there is **no `cs` field** — so `$.cs[i]` would read
`undefined`. This looks like the same latent defect (the typed path was copied
from it). It does not crash the compiler (the JS backend does no
monomorphization type-walk), but 3-tuple outgoing ports on the JS backend are
likely mis-encoded. Worth a follow-up; not required to fix the reported crash.

---

## 9. How this was traced (dev loop)

The native `eco` binary is produced by a slow multi-stage bootstrap. The same
compiler **Elm source** runs much faster as JavaScript via the guida-built
`eco-boot.js` under node, and it reproduces the crash identically:

```bash
node /work/build/compiler/build-kernel/bin/eco-boot-runner.js \
     make src/elm/Top.elm --output=test.mlir \
     --local-package eco/kernel=/work/eco-kernel-cpp
```

(The explicit `--local-package` flag is required only to dodge an unrelated
`_Runtime_dirname` JS-kernel stub that is forced when the kernel path is
auto-located.)

Loop: edit `Specialize.elm` / `Port.elm` → rebuild `eco-boot.js` via guida
(`node compiler/bin/index.js make …`, ~4–50s incremental) → run the JS compiler
under node. This made instrument → rebuild → re-run iterations cheap enough to
capture the trace in §3 directly.

module LssGapCtorRebuild exposing (main)

{-| ⊤-MANUFACTURE probe (plans/lss-ctor-arrow-identity.md §9).

The self-compile's single largest ⊤ class is `declZonk` — the STORELESS
classification path, which stamps ⊤ on every arrow by construction. 1,233
positions carry it, and 528 of those (96 % of the ctor share) belong to two
constructors: `Compiler.Parse.Primitives.Cerr` / `Eerr`, whose payload field
is a deferred error builder:

    type PStep x a = Cok a State | Eok a State
                   | Cerr Row Col (Row -> Col -> x)
                   | Eerr Row Col (Row -> Col -> x)

The split is per-SPEC, not per-position: at `Cerr|/r/r/a0` 172 specs read k1
while 132 read ⊤. So some construction sites take the store-aware path and
others take a storeless one. The candidate shapes are below, one rung each,
so a single compile says which of them manufactures the ⊤.

  - `rebuilt`  — DESTRUCTURE-AND-REBUILD inside a generic function, exactly
    `Primitives.elm:157` (`Cerr r c t -> Cerr r c t`). The payload is a
    destructor-bound local; if its use-site type is recorded as a variable
    rather than an arrow, `canTypeHasArrow` says False, `lssFastOk` admits
    the call to the cached storeless scheme, and the whole demand — payload
    arrow included — is stamped ⊤.
  - `wrapped`  — a GENERIC wrapper `wrapAny : a -> Box a` instantiated at
    `a = (Int -> Int)`: the argument's syntactic type is a bare type
    variable, the same `canTypeHasArrow` blind spot from the other side.
  - `direct`   — the control: the ctor applied to a known lambda in situ.
    This one should be covered; if it is not, the diagnosis is wrong.
  - `viaId`    — the value passed through a polymorphic identity, so the
    ctor's payload crosses an item boundary with no syntactic arrow in view.

Read with `ECO_MONO_LSS_REPORT=1 ECO_MONO_LSS_ARROW_CENSUS=1`, grep `^pos|`;
the decisive rows are `Cerr2|/r/a0` and `Box|/a0` and their `top@<kind>` tags.

-}

-- CHECK: ctorRebuild: 33

import Html exposing (text)


type PS x
    = Ok2 Int
    | Cerr2 Int (Int -> x)


type Box a
    = Box a


{-| The `Primitives.map` shape: generic, destructures every arm and rebuilds
the error arms verbatim. `t` is a destructor-bound local.
-}
mapPS : (Int -> Int) -> PS x -> PS x
mapPS f ps =
    case ps of
        Ok2 n ->
            Ok2 (f n)

        Cerr2 r t ->
            Cerr2 r t


runPS : PS Int -> Int
runPS ps =
    case ps of
        Ok2 n ->
            n

        Cerr2 r t ->
            r + t 1


{-| Generic wrapper: `v`'s syntactic type here is the type VARIABLE `a`.
-}
wrapAny : a -> Box a
wrapAny v =
    Box v


unBox : Box (Int -> Int) -> Int
unBox (Box g) =
    g 5


idf : a -> a
idf v =
    v


bump : Int -> Int
bump n =
    n + 1


main =
    let
        rebuilt =
            runPS (mapPS bump (Cerr2 10 (\i -> i + 2)))

        direct =
            runPS (Cerr2 4 (\i -> i * 2))

        wrapped =
            unBox (wrapAny bump)

        viaId =
            runPS (idf (Cerr2 3 (\i -> i + 4)))

        _ =
            Debug.log "ctorRebuild" (rebuilt + direct + wrapped + viaId)
    in
    text "h"

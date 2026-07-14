module DestructCaptureTest exposing (main)

{-| Standalone pin for the destructure-binder capture bug: the inliner's
`freshenLetBoundNames` renamed MonoDef/MonoTailDef binders in
instantiated bodies but passed `MonoDestruct` binders through verbatim.
Inlining `swap` (whose body destructures an OPAQUE pair into a binder
named `x`) into a caller with its OWN `x` used afterwards captured the
caller's reference (this test printed 11 instead of 56 pre-fix). Found
via the ECO_ARITY_RAISE=1 native self-compile segfault (raised
`andThen`'s destructure binder `a` captured `constrainTupleWithIds`'s
source param `a`), but reachable FLAG-OFF as this shape shows. The pair
must come from a non-inlinable call — a literal tuple folds at Mono and
the destruct never materializes.
-}

import Html exposing (text)

-- CHECK: captured: 56


mk : Int -> ( Int, Int )
mk n =
    if n > 100 then
        mk (n - 100)

    else
        ( n, n + 1 )


swap : ( Int, Int ) -> ( Int, Int )
swap pair =
    let
        ( x, y ) =
            pair
    in
    ( y, x )


f : Int -> Int
f a =
    let
        x =
            a * 10

        swapped =
            swap (mk a)
    in
    Tuple.first swapped + x


main =
    let
        _ =
            Debug.log "captured" (f 5)
    in
    text "done"

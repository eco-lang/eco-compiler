module LssGapCtorTypeArgFn exposing (main)

{-| Q2 probe: `/c<n>` in the pos| census indexes a custom type's TYPE ARGUMENTS
(0-based), so a payload arrow is census-visible only in a type-parameter slot.
`Holder e a` at `a = (Int -> Int)` puts an arrow at `/r/c1` of `mk` and `/a0/c1`
of `run` — the population LssGapCustomTypeFn/RecordField/ListOfFns cannot reach
(all three use a non-parameterized arity-1 payload). Producer and consumer are
different ITEMS on purpose: the expected diagnosis is per-item store teardown
(`knownElsewhere`), not a missing injection at the construction site.
-}

-- CHECK: ctorTypeArgFn: 12

import Html exposing (text)


type Holder e a
    = Holder e a


mk : Int -> Holder Int (Int -> Int)
mk n =
    Holder n (\x -> x + n)


run : Holder Int (Int -> Int) -> Int
run (Holder n f) =
    f n


main =
    let
        _ =
            Debug.log "ctorTypeArgFn" (run (mk 6))
    in
    text "hello"

module LssGapCtorTypeArgFn exposing (main)

{-| A function stored in a custom type through a type parameter can be built in
one function and applied in another.

`Holder e a` is used at `a = (Int -> Int)`: `mk 6` builds
`Holder 6 (\x -> x + 6)` and `run` destructures it and applies the function
to the stored Int, printing 12.

## eco

A lambda-set specialization (LSS) census probe: `/c<n>` in the `pos|` census
indexes a custom type's type arguments (0-based), so a payload arrow is visible
to the census only in a type-parameter slot. `Holder e a` at `a = (Int -> Int)`
puts an arrow at `/r/c1` of `mk` and `/a0/c1` of `run`, which
test/elm/src/LssGapCustomTypeFn.elm, test/eco-elm/src/LssGapRecordField.elm and
test/eco-elm/src/LssGapListOfFns.elm cannot reach. Producer and consumer are
different items on purpose: the expected loss is per-item store teardown
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

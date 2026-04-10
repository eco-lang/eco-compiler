module MaybeMapTypeMismatchTest exposing (main)

{-| Test Maybe.map where the mapping function's return type differs
from the input type. The mapping function returns Bool (embedded constant)
but the input is Float. If the monomorphizer incorrectly unifies input
and output types, the generated code will try to resolve Bool as a
heap Float and crash.
-}

-- CHECK: r1: Just True
-- CHECK: r2: Just False

import Html exposing (text)


main =
    let
        r1 =
            Just 1.0
                |> Maybe.map (\x -> x > 0)

        r2 =
            Just -1.0
                |> Maybe.map (\x -> x > 0)

        _ = Debug.log "r1" r1
        _ = Debug.log "r2" r2
    in
    text "done"

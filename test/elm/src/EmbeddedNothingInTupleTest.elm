module EmbeddedNothingInTupleTest exposing (main)

{-| A tuple pattern in a `let` takes `Nothing` and `Just 42` back out of a pair,
and each matches the right pattern.
-}

-- CHECK: first: "nothing"
-- CHECK: second: 42

import Html exposing (text)


main =
    let
        pair =
            ( Nothing, Just 42 )

        ( a, b ) =
            pair

        first =
            case a of
                Just _ ->
                    "just"

                Nothing ->
                    "nothing"

        second =
            case b of
                Just x ->
                    x

                Nothing ->
                    -1

        _ = Debug.log "first" first
        _ = Debug.log "second" second
    in
    text "done"

module LetBoundLambdaCallTest exposing (main)

{-| A two-argument anonymous function bound in a `let` and then applied to two
arguments: `(\x y -> x) 1 2` returns the first, 1.
-}

-- CHECK: result: 1

import Html exposing (text)


main =
    let
        f = \x y -> x

        result = f 1 2
        _ = Debug.log "result" result
    in
    text "done"

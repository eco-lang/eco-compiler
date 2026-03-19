module LetBoundLambdaCallTest exposing (main)

{-| Test let-bound lambda expression called with two args.
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

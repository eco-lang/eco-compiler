module LetRecMultiArgTest exposing (main)

{-| A recursive two-argument function defined in a `let` block calls itself with
both arguments changed; `f 1 1` logs `result: 2`.
-}

-- CHECK: result: 2

import Html exposing (text)


main =
    let
        f a b =
            if a <= 0 then b else f (a - 1) (b + 1)

        result = f 1 1
        _ = Debug.log "result" result
    in
    text "done"

module LetRecMultiArgTest exposing (main)

{-| Test recursive let-bound function with multiple args.
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

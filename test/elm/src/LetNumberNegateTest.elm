module LetNumberNegateTest exposing (main)

{-| An unannotated let-bound integer literal passed through `negate` twice and then
to `sqrt` is used as a `Float`: `round (sqrt (negate (negate n)))` with
`n = 144` logs 12.

`negate` works on any `number`, so it is `sqrt` that fixes `n` to `Float`.

-}

-- CHECK: neg: 12

import Html exposing (text)


main =
    let
        n =
            144

        result =
            round (sqrt (negate (negate n)))

        _ =
            Debug.log "neg" result
    in
    text "done"

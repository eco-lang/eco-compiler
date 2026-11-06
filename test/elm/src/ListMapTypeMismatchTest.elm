module ListMapTypeMismatchTest exposing (main)

{-| Checks `List.map` with a function from `Int` to `Bool`, testing which elements
of `[1, -1, 2]` are positive.
-}

-- CHECK: result: [True,False,True]

import Html exposing (text)


main =
    let
        result =
            List.map (\x -> x > 0) [ 1, -1, 2 ]

        _ = Debug.log "result" result
    in
    text "done"

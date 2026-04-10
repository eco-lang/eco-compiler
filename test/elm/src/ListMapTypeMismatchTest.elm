module ListMapTypeMismatchTest exposing (main)

{-| Test List.map with Int -> Bool mapping function.
Same monomorphization issue as Maybe.map but for List.
-}

-- CHECK: result: [True, False, True]

import Html exposing (text)


main =
    let
        result =
            List.map (\x -> x > 0) [ 1, -1, 2 ]

        _ = Debug.log "result" result
    in
    text "done"

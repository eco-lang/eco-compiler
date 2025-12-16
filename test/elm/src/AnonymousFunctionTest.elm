module AnonymousFunctionTest exposing (main)

{-| Test anonymous functions (lambdas).
-}

-- CHECK: lambda1: [2,4,6]
-- CHECK: lambda2: 15
-- CHECK: lambda3: [2,4]

import Html exposing (text)


main =
    let
        _ = Debug.log "lambda1" (List.map (\x -> x * 2) [1, 2, 3])
        _ = Debug.log "lambda2" (List.foldl (\x acc -> x + acc) 0 [1, 2, 3, 4, 5])
        _ = Debug.log "lambda3" (List.filter (\x -> modBy 2 x == 0) [1, 2, 3, 4, 5])
    in
    text "done"

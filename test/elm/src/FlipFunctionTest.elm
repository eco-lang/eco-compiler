module FlipFunctionTest exposing (main)

{-| Test flip function with type annotation.
-}

-- CHECK: result: 3.14

import Html exposing (text)


flip : (a -> b -> c) -> b -> a -> c
flip f y x = f x y


main =
    let
        result = flip (\a b -> 3.14) "world" 7
        _ = Debug.log "result" result
    in
    text "done"

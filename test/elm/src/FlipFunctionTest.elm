module FlipFunctionTest exposing (main)

{-| A locally defined, annotated `flip` swaps the two arguments of the function it is given.

`flip (\a b -> 3.14) "world" 7` calls the lambda with 7 and `"world"`, which ignores both and returns 3.14.
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

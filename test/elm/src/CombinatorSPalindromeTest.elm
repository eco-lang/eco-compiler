module CombinatorSPalindromeTest exposing (main)

{-| S combinator with String.reverse: "straw" ++ reverse "straw" = "strawwarts"
-}

-- CHECK: result: strawwarts

import Html exposing (text)


s bf uf x = bf x (uf x)


main =
    let
        _ = Debug.log "result" (s (++) String.reverse "straw")
    in
    text "done"

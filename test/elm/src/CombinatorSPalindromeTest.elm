module CombinatorSPalindromeTest exposing (main)

{-| The S combinator with `String.reverse`: `s (++) String.reverse "straw"` is `"straw" ++ String.reverse "straw"`, which is `"strawwarts"`.
-}

-- CHECK: result: "strawwarts"

import Html exposing (text)


s bf uf x = bf x (uf x)


main =
    let
        _ = Debug.log "result" (s (++) String.reverse "straw")
    in
    text "done"

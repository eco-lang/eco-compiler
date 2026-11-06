module StringFoldlTest exposing (main)

{-| Checks that `String.foldl` visits characters from the left and `String.foldr` from the right.

Both fold `String.cons` over `"hello"` starting from `""`. Consing from the left
reverses the string, giving `"olleh"`; consing from the right rebuilds it,
giving `"hello"`.

-}

-- CHECK: foldl1: "olleh"
-- CHECK: foldr1: "hello"

import Html exposing (text)

main =
    let
        _ = Debug.log "foldl1" (String.foldl (\c acc -> String.cons c acc) "" "hello")
        _ = Debug.log "foldr1" (String.foldr (\c acc -> String.cons c acc) "" "hello")
    in
    text "done"

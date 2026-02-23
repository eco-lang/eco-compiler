module StringFoldlTest exposing (main)

-- CHECK: foldl1: "olleh"
-- CHECK: foldr1: "hello"

import Html exposing (text)

main =
    let
        _ = Debug.log "foldl1" (String.foldl (\c acc -> String.cons c acc) "" "hello")
        _ = Debug.log "foldr1" (String.foldr (\c acc -> String.cons c acc) "" "hello")
    in
    text "done"

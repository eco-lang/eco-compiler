module StringWordsLinesTest exposing (main)

-- CHECK: words1: ["hello", "world"]
-- CHECK: lines1: ["line1", "line2"]

import Html exposing (text)

main =
    let
        _ = Debug.log "words1" (String.words "hello world")
        _ = Debug.log "lines1" (String.lines "line1\nline2")
    in
    text "done"

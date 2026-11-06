module StringWordsLinesTest exposing (main)

{-| `String.words` splits `"hello world"` at the space and `String.lines`
splits `"line1\nline2"` at the newline, each into two parts.
-}

-- CHECK: words1: ["hello","world"]
-- CHECK: lines1: ["line1","line2"]

import Html exposing (text)

main =
    let
        _ = Debug.log "words1" (String.words "hello world")
        _ = Debug.log "lines1" (String.lines "line1\nline2")
    in
    text "done"

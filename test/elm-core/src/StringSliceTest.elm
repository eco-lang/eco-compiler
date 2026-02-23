module StringSliceTest exposing (main)

-- CHECK: slice1: "ell"
-- CHECK: slice_neg: "ell"
-- CHECK: slice_start: "Hel"
-- CHECK: slice_end: "rld"

import Html exposing (text)

main =
    let
        _ = Debug.log "slice1" (String.slice 1 4 "Hello")
        _ = Debug.log "slice_neg" (String.slice 1 -1 "Hello")
        _ = Debug.log "slice_start" (String.slice 0 3 "Hello World")
        _ = Debug.log "slice_end" (String.slice -3 (String.length "World") "World")
    in
    text "done"

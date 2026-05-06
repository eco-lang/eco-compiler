module EscapeRecordPapCaptureTest exposing (main)

{-| Phase 2 negative: a record captured by a partial application
escapes via the closure environment. eco.make.record rewriting is
suppressed and the heap path is used; behaviour must still match.
-}

-- CHECK: result: 30


import Html exposing (text)


-- The record literal flows into a closure capture (the partial
-- application of `combine` saturates only the first arg, so `rec`
-- is stored in the resulting closure).
combine : { x : Int, y : Int } -> Int -> Int
combine rec n =
    rec.x + rec.y + n


main =
    let
        adder =
            combine { x = 10, y = 17 }

        _ =
            Debug.log "result" (adder 3)
    in
    text "done"

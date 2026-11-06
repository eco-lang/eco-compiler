module EscapeRecordPapCaptureTest exposing (main)

{-| A function partially applied to a record literal reads that record's fields when it is later given its last argument.

`combine { x = 10, y = 17 }` is bound to `adder`, and `adder 3` is 10 + 17 + 3 = 30.

## eco

Exercises the escape guard of eco's record scalar-replacement rewrite: the
record literal is stored in the closure environment of the partial application
`combine { x = 10, y = 17 }`, so it escapes and the `eco.make.record`
rewriting is suppressed; the heap record path must be used and give the same
answer.

-}

-- CHECK: result: 30


import Html exposing (text)


{-| Returns the sum of the record's two fields and `n`.
-}
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

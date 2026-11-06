module StringConcatContentTest exposing (main)

{-| A chain of twenty `++` operations and `String.concat` of a long list both
produce the right text.

The chain joins the single letters `a` to `j` and `A` to `J`. `String.concat`
joins 100 copies of `"xy"`; the test logs its length, 200, and its first four
characters.

-}

-- CHECK: concat20: "abcdefghijABCDEFGHIJ"
-- CHECK: concat_len: 200
-- CHECK: concat_head: "xyxy"

import Html exposing (text)


main =
    let
        concat20 =
            "a" ++ "b" ++ "c" ++ "d" ++ "e" ++ "f" ++ "g" ++ "h" ++ "i" ++ "j" ++ "A" ++ "B" ++ "C" ++ "D" ++ "E" ++ "F" ++ "G" ++ "H" ++ "I" ++ "J"

        listConcat =
            String.concat (List.repeat 100 "xy")

        _ =
            Debug.log "concat20" concat20

        _ =
            Debug.log "concat_len" (String.length listConcat)

        _ =
            Debug.log "concat_head" (String.left 4 listConcat)
    in
    text "done"

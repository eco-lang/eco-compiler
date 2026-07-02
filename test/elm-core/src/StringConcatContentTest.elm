module StringConcatContentTest exposing (main)

{-| G3/E16: many-operand ++ and String.concat, asserting content correctness
(the gated suite never checks concat output for correctness). A 20-way ++ chain
and String.concat of 100 "xy" pieces.
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

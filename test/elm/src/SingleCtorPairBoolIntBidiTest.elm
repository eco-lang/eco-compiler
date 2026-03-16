module SingleCtorPairBoolIntBidiTest exposing (main)

{-| Two single-constructor types: WrapBool (Bool, boxed) and WrapInt (Int, i64 unboxed).
Tests BOTH directions: matching on WrapBool (should not use i64 layout from WrapInt)
AND matching on WrapInt (should not use boxed layout from WrapBool).
-}

-- CHECK: match_true: "yes"
-- CHECK: match_false: "no"
-- CHECK: match_pos: "positive"
-- CHECK: match_neg: "non-positive"
-- CHECK: extract_bool: True
-- CHECK: extract_int: 42

import Html exposing (text)


type WrapBool
    = WrapBool Bool


type WrapInt
    = WrapInt Int


matchBool : Bool -> String
matchBool b =
    let
        w =
            WrapBool b
    in
    case w of
        WrapBool True ->
            "yes"

        WrapBool False ->
            "no"


matchInt : Int -> String
matchInt n =
    let
        w =
            WrapInt n
    in
    case w of
        WrapInt x ->
            if x > 0 then
                "positive"

            else
                "non-positive"


extractBool : WrapBool -> Bool
extractBool w =
    case w of
        WrapBool b ->
            b


extractInt : WrapInt -> Int
extractInt w =
    case w of
        WrapInt n ->
            n


main =
    let
        _ = Debug.log "match_true" (matchBool True)
        _ = Debug.log "match_false" (matchBool False)
        _ = Debug.log "match_pos" (matchInt 7)
        _ = Debug.log "match_neg" (matchInt -3)
        _ = Debug.log "extract_bool" (extractBool (WrapBool True))
        _ = Debug.log "extract_int" (extractInt (WrapInt 42))
    in
    text "done"

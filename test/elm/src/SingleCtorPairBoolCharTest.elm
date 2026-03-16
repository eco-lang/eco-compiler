module SingleCtorPairBoolCharTest exposing (main)

{-| Two single-constructor types: WrapBool (Bool, boxed) and WrapChar (Char, i16 unboxed).
Tests that case-matching on WrapBool doesn't use WrapChar's unboxed i16 layout.
-}

-- CHECK: match_true: "yes"
-- CHECK: match_false: "no"
-- CHECK: unwrap_char: 'x'

import Html exposing (text)


type WrapBool
    = WrapBool Bool


type WrapChar
    = WrapChar Char


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


unwrapChar : WrapChar -> Char
unwrapChar w =
    case w of
        WrapChar c ->
            c


main =
    let
        _ = Debug.log "match_true" (matchBool True)
        _ = Debug.log "match_false" (matchBool False)
        _ = Debug.log "unwrap_char" (unwrapChar (WrapChar 'x'))
    in
    text "done"

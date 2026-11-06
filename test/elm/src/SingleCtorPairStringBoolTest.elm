module SingleCtorPairStringBoolTest exposing (main)

{-| Pattern matching works on two single-constructor types in one module, one wrapping a `String` and one wrapping a `Bool`.

`unwrapString` returns the wrapped `"world"`. `matchBool` matches the literal
patterns `WrapBool True` and `WrapBool False`, giving `"yes"` and `"no"`.

-}

-- CHECK: unwrap_str: "world"
-- CHECK: match_true: "yes"
-- CHECK: match_false: "no"

import Html exposing (text)


type WrapString
    = WrapString String


type WrapBool
    = WrapBool Bool


unwrapString : WrapString -> String
unwrapString w =
    case w of
        WrapString s ->
            s


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


main =
    let
        _ = Debug.log "unwrap_str" (unwrapString (WrapString "world"))
        _ = Debug.log "match_true" (matchBool True)
        _ = Debug.log "match_false" (matchBool False)
    in
    text "done"

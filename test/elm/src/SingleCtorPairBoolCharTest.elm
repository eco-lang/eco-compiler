module SingleCtorPairBoolCharTest exposing (main)

{-| Pattern matching works on two single-constructor types in one module, one wrapping a `Bool` and one wrapping a `Char`.

`matchBool` wraps a `Bool` in `WrapBool` and matches the literal patterns
`WrapBool True` and `WrapBool False`, giving `"yes"` and `"no"`. `unwrapChar`
extracts the `Char` from `WrapChar 'x'`.

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

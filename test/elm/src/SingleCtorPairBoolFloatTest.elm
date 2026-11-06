module SingleCtorPairBoolFloatTest exposing (main)

{-| Pattern matching works on two single-constructor types in one module, one wrapping a `Bool` and one wrapping a `Float`.

`matchBool` wraps a `Bool` in `WrapBool` and matches the literal patterns
`WrapBool True` and `WrapBool False`, giving `"yes"` and `"no"`. `unwrapFloat`
extracts the `Float` from `WrapFloat 3.14`.

-}

-- CHECK: match_true: "yes"
-- CHECK: match_false: "no"
-- CHECK: unwrap_float: 3.14

import Html exposing (text)


type WrapBool
    = WrapBool Bool


type WrapFloat
    = WrapFloat Float


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


unwrapFloat : WrapFloat -> Float
unwrapFloat w =
    case w of
        WrapFloat f ->
            f


main =
    let
        _ = Debug.log "match_true" (matchBool True)
        _ = Debug.log "match_false" (matchBool False)
        _ = Debug.log "unwrap_float" (unwrapFloat (WrapFloat 3.14))
    in
    text "done"

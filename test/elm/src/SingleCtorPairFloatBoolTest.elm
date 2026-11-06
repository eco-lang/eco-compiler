module SingleCtorPairFloatBoolTest exposing (main)

{-| Pattern matching works on two single-constructor types in one module, one wrapping a `Float` and one wrapping a `Bool`.

`unwrapFloat` returns the wrapped `9.81`. `matchBool` matches the literal
patterns `WrapBool True` and `WrapBool False`, giving `"yes"` and `"no"`.
`matchFloat` binds the wrapped `Float` and compares it with 5.0, giving `"big"`
for 100.0.

-}

-- CHECK: unwrap_float: 9.81
-- CHECK: match_true: "yes"
-- CHECK: match_false: "no"
-- CHECK: match_float: "big"

import Html exposing (text)


type WrapFloat
    = WrapFloat Float


type WrapBool
    = WrapBool Bool


unwrapFloat : WrapFloat -> Float
unwrapFloat w =
    case w of
        WrapFloat f ->
            f


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


matchFloat : Float -> String
matchFloat f =
    let
        w =
            WrapFloat f
    in
    case w of
        WrapFloat x ->
            if x > 5.0 then
                "big"

            else
                "small"


main =
    let
        _ = Debug.log "unwrap_float" (unwrapFloat (WrapFloat 9.81))
        _ = Debug.log "match_true" (matchBool True)
        _ = Debug.log "match_false" (matchBool False)
        _ = Debug.log "match_float" (matchFloat 100.0)
    in
    text "done"

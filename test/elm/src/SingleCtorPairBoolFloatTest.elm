module SingleCtorPairBoolFloatTest exposing (main)

{-| Two single-constructor types: WrapBool (Bool, boxed) and WrapFloat (Float, f64 unboxed).
Tests that case-matching on WrapBool doesn't use WrapFloat's unboxed f64 layout.
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

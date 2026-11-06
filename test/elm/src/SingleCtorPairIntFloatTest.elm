module SingleCtorPairIntFloatTest exposing (main)

{-| Values are extracted correctly from two single-constructor types in one module, one wrapping an `Int` and one wrapping a `Float`.

`unwrapInt` and `unwrapFloat` return the wrapped `42` and `2.718`. `matchInt`
gives `"positive"` for 7, and `matchFloat` gives `"big"` for 999.9, which is
above its threshold of 100.0.

-}

-- CHECK: unwrap_int: 42
-- CHECK: unwrap_float: 2.718
-- CHECK: match_int_pos: "positive"
-- CHECK: match_float_big: "big"

import Html exposing (text)


type WrapInt
    = WrapInt Int


type WrapFloat
    = WrapFloat Float


unwrapInt : WrapInt -> Int
unwrapInt w =
    case w of
        WrapInt n ->
            n


unwrapFloat : WrapFloat -> Float
unwrapFloat w =
    case w of
        WrapFloat f ->
            f


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


matchFloat : Float -> String
matchFloat f =
    let
        w =
            WrapFloat f
    in
    case w of
        WrapFloat x ->
            if x > 100.0 then
                "big"

            else
                "small"


main =
    let
        _ = Debug.log "unwrap_int" (unwrapInt (WrapInt 42))
        _ = Debug.log "unwrap_float" (unwrapFloat (WrapFloat 2.718))
        _ = Debug.log "match_int_pos" (matchInt 7)
        _ = Debug.log "match_float_big" (matchFloat 999.9)
    in
    text "done"
